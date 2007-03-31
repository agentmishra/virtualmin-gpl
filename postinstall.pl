
$force_load_features = 1;	# so that the latest feature-* files are used
$done_virtual_server_lib_funcs = 0;
do 'virtual-server-lib.pl';

sub module_install
{
# Make sure the remote.cgi page is accessible in non-session mode
local %miniserv;
&get_miniserv_config(\%miniserv);
if ($virtualmin_pro) {
	local @sa = split(/\s+/, $miniserv{'sessiononly'});
	if (&indexof("/$module_name/remote.cgi", @sa) < 0) {
		# Need to add
		push(@sa, "/$module_name/remote.cgi");
		$miniserv{'sessiononly'} = join(" ", @sa);
		}
	}

# Setup the default templates
foreach my $tf (@all_template_files) {
	&ensure_template($tf);
	}

# Perform a module config check, to ensure that quota and interface settings
# are correct.
&set_all_null_print();
$cerr = &html_tags_to_text(&check_virtual_server_config());
#if ($cerr) {
#	print STDERR "Warning: Module Configuration problem detected: $cerr\n";
#	}

# Force update of all Webmin users, to set new ACL options
&modify_all_webmin();
if ($virtualmin_pro) {
	&modify_all_resellers();
	}

# Setup the licence cron job
&setup_licence_cron();

# Fix up Procmail default delivery
if ($config{'spam'} && $virtualmin_pro) {
	&setup_default_delivery();
	}

# Fix up old procmail scripts that don't call the clam wrapper
if ($config{'virus'} && $virtualmin_pro) {
	&fix_clam_wrapper();
	}

if ($virtualmin_pro) {
	# Configure miniserv to pre-load virtual-server-lib-funcs.pl and
	# all of the feature files
	local @preload = split(/\s+/, $miniserv{'preload'});
	foreach my $pf (@preload) {
		local ($p, $f) = split(/=/, $pf);
		$preloaded{$p,$f} = 1;
		}
	local $need_restart;
	local $vslf = "virtual-server/virtual-server-lib-funcs.pl";
	if (!$preloaded{"virtual-server",$vslf}) {
		push(@preload,
		   "virtual-server=$vslf");
		$need_restart = 1;
		}
	foreach my $f (@features, "virt") {
		local $file = "virtual-server/feature-$f.pl";
		if (!$preloaded{"virtual-server",$file}) {
			push(@preload, "virtual-server=$file");
			$need_restart = 1;
			}
		}

	# Pre-load web-lib.pl for all modules used by Virtualmin
	local $file = "web-lib-funcs.pl";
	foreach my $minfo (&get_all_module_infos()) {
		local $mdir = &module_root_directory($minfo->{'dir'});
		if (-r "$mdir/virtual_feature.pl" ||
		    &indexof($minfo->{'dir'}, @used_webmin_modules) >= 0 ||
		    $minfo->{'dir'} eq "virtual-server") {
			if (!$preloaded{$minfo->{'dir'},$file}) {
				push(@preload, "$minfo->{'dir'}=$file");
				$need_restart = 1;
				}
			}
		}
	$miniserv{'preload'} = join(" ", &unique(@preload));
	}

if ($virtualmin_pro) {
	# Run in package eval mode, to avoid loading the same module twice
	$miniserv{'eval_package'} = 1;
	}
&put_miniserv_config(\%miniserv);
&restart_miniserv();

# Setup lookup domain daemon
if ($virtualmin_pro) {
	&foreign_require("init", "init-lib.pl");
	&foreign_require("proc", "proc-lib.pl");
	local $pidfile = "$ENV{'WEBMIN_VAR'}/lookup-domain-daemon.pid";
	&init::enable_at_boot(
	      "lookup-domain",
	      "Daemon for quickly looking up Virtualmin ".
	      "servers from procmail",
	      "$module_root_directory/lookup-domain-daemon.pl",
	      "kill `cat $pidfile`",
	      undef);
	if (&check_pid_file($pidfile)) {
		&init::stop_action("lookup-domain");
		sleep(5);	# Let port free up
		}
	&init::start_action("lookup-domain");
	}

# Force a restart of Apache, to apply writelogs.pl changes
if ($config{'web'}) {
	&require_apache();
	&restart_apache();
	}

if ($virtualmin_pro) {
	# Create links for existing autoreply aliases
	&set_alias_programs();
	foreach my $d (&list_domains()) {
		if ($d->{'mail'}) {
			&create_autoreply_alias_links($d);
			}
		}
	}

# If installing for the first time, enable backup of all features by default
local @doms = &list_domains();
if (!@doms && !defined($config{'backup_feature_all'})) {
	$config{'backup_feature_all'} = 1;
	&save_module_config();
	}

# Build quick domain-lookup maps
&build_domain_maps();

# If supported by OpenSSH, create a group of users to deny SSH for
if (&foreign_installed("sshd")) {
	# Add to SSHd config
	&foreign_require("sshd", "sshd-lib.pl");
	local $conf = &sshd::get_sshd_config();
	local @denyg = &sshd::find_value("DenyGroups", $conf);
	local $commas = $sshd::version{'type'} eq 'ssh' &&
			$sshd::version{'number'} >= 3.2;
	if ($commas) {
		@denyg = split(/,/, $denyg[0]);
		}
	if (&indexof($denied_ssh_group, @denyg) < 0) {
		push(@denyg, $denied_ssh_group);
		&sshd::save_directive("DenyGroups", $conf,
				       join($commas ? "," : " ", @denyg));
		&flush_file_lines($sshd::config{'sshd_config'});
		&sshd::restart_sshd();
		}

	# Create the actual group, if missing
	&require_useradmin();
	local @allgroups = &list_all_groups();
	local ($group) = grep { $_->{'group'} eq $denied_ssh_group } @allgroups;
	if (!$group) {
		local (%gtaken, %ggtaken);
		&build_group_taken(\%gtaken, \%ggtaken, \@allgroups);
		$group = { 'group' => $denied_ssh_group,
			   'members' => '',
			   'gid' => &allocate_gid(\%gtaken) };
		&foreign_call($usermodule, "lock_user_files");
		&foreign_call($usermodule, "set_group_envs", $group,
							     'CREATE_GROUP');
		&foreign_call($usermodule, "making_changes");
		&foreign_call($usermodule, "create_group", $group);
		&foreign_call($usermodule, "made_changes");
		&foreign_call($usermodule, "unlock_user_files");
		}
	}
&build_denied_ssh_group();

if ($virtualmin_pro) {
	# Create the cron job for sending in script ratings
	&foreign_require("cron", "cron-lib.pl");
	local ($job) = grep { $_->{'user'} eq 'root' &&
			      $_->{'command'} eq $ratings_cron_cmd }
			    &cron::list_cron_jobs();
	if (!$job) {
		# Create, and run for the first time
		$job = { 'mins' => int(rand()*60),
			 'hours' => int(rand()*24),
			 'days' => '*',
			 'months' => '*',
			 'weekdays' => '*',
			 'user' => 'root',
			 'active' => 1,
			 'command' => $ratings_cron_cmd };
		&cron::create_cron_job($job);
		&cron::create_wrapper($ratings_cron_cmd, $module_name,
				      "sendratings.pl");
		&execute_command($ratings_cron_cmd);
		}
	}
}

