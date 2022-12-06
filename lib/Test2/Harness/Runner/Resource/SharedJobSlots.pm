package Test2::Harness::Runner::Resource::SharedJobSlots;
use strict;
use warnings;

our $VERSION = '1.000138';

use YAML::Tiny;
use Test2::Harness::Runner::Resource::SharedJobSlots::State;

use App::Yath::Util qw/find_in_updir/;
use Sys::Hostname qw/hostname/;
use Time::HiRes qw/time/;
use List::Util qw/min/;
use Carp qw/confess/;

use parent 'Test2::Harness::Runner::Resource';
use Test2::Harness::Util::HashBase qw{
    <settings
    <state
    <config
    <runner_id
    <runner_pid
    <job_limiter_max
    <observe
};

sub job_limiter { 1 }

sub new {
    my $class = shift;
    my $self = bless {@_}, $class;
    $self->init();
    return $self;
}

sub get_config {
    my $class = shift;
    my ($config_file) = @_;

    return () unless $config_file;

    $config_file = find_in_updir($config_file) if $config_file !~ m{(/|\\)} && ! -e $config_file;

    return () unless $config_file && -e $config_file;

    my $config = YAML::Tiny->read($config_file) or die "Could not read '$config_file'";
    $config = $config->[0]; # First doc only
    for my $host (hostname(), 'DEFAULT') {
        my $host_conf = $config->{$host} or next;
        return ($config_file, $host, $host_conf);
    }

    return ();
}

sub init {
    my $self     = shift;
    my $settings = $self->{+SETTINGS};

    my $config_path = $settings->runner->shared_jobs_config;
    my ($config_file, $host, $host_conf) = $self->get_config($config_path);
    die "Could not find shared jobs config '$config_path'.\n"
        unless $config_file;

    die "Could not find '" . hostname() ."' or 'DEFAULT' settings in '$config_file'.\n"
        unless $host && $host_conf;

    if ($host eq 'DEFAULT' && !$host_conf->{no_warning}) {
        warn <<"        EOT";
Using the 'DEFAULT' shared-slots host config.
You may want to add the current host to the config file.
To silence this warning, set the 'no_warning' key to true in the DEFAULT host config.
Config file: $config_file
        EOT
    }

    my $algorithm = $host_conf->{algorithm} // 'fair';
    if ($algorithm =~ m/^(.*)::([^:]+)$/) {
        my ($mod, $sub) = ($1, $2);
        require(mod2file($mod));
    }
    else {
        my $short = $algorithm;
        $algorithm = "_redistribute_$algorithm";
        die "'$short' is not a valid algorith (in file '$config_file' under hist '$host' key 'algorithm'). Must be 'fair', 'first', or a Fully::Qualified::Module::function_name."
            unless Test2::Harness::Runner::Resource::SharedJobSlots::State->can($algorithm);
    }

    my $runner_id  = $self->{+RUNNER_ID}  //= $settings->runner->runner_id if $settings->check_prefix('runner');
    my $runner_pid = $self->{+RUNNER_PID} //= $Test2::Harness::Runner::RUNNER_PID // $App::Yath::Command::runner::RUNNER_PID;

    my $prefix = $settings->debug->procname_prefix // '';
    my $name   = $settings->harness->project       // '';

    my $dir;
    if (my $path = $settings->harness->config_file) {
        if ($path =~ m{^(.*)/[^/]+$}) {
            $dir = $1;
        }
    }

    $dir //= $settings->harness->cwd;

    unless ($name) {
        $name = $dir;
        $name =~ s{^.*/}{};
    }

    $name = "$prefix-$name" if $prefix;

    $self->{+JOB_LIMITER_MAX} = min(grep { $_ } $host_conf->{max_slots_per_run}, $settings->runner->job_count);

    my $max_slots   = $host_conf->{max_slots}         // die("'max_slots' not set in '$config_file' for host '$host'.\n");
    my $max_per_run = $host_conf->{max_slots_per_run} // die("'max_slots_per_run' not set in '$config_file' for host '$host'.\n");
    my $max_per_job = $host_conf->{max_slots_per_job} // die("'max_slots_per_job' not set in '$config_file' for host '$host'.\n");
    my $min_per_run = $host_conf->{min_slots_per_run} // 0;

    $self->{+STATE} = Test2::Harness::Runner::Resource::SharedJobSlots::State->new(
        dir               => $dir,
        name              => $name,
        runner_id         => $runner_id,
        runner_pid        => $runner_pid,
        state_umask       => $host_conf->{state_umask} // 0007,
        state_file        => $host_conf->{state_file}  // die("'state_file' not set in '$config_file' for host '$host'.\n"),
        max_slots         => $max_slots,
        max_slots_per_job => $max_per_job,
        max_slots_per_run => $max_per_run,
        min_slots_per_run => $min_per_run,
        algorithm         => $algorithm,

        my_max_slots         => min($self->settings->runner->job_count,     $max_slots),
        my_max_slots_per_job => min($self->settings->runner->slots_per_job, $max_per_job),
    );

    $self->{+CONFIG} = $host_conf;

    return;
}

# Disable this short-circuit otherwise we may never queue a request!
sub job_limiter_at_max { 0 }

sub refresh { $_[0]->{+STATE}->update_registration }

sub _job_concurrency {
    my $self = shift;
    my ($task) = @_;

    my $rmax = $self->settings->runner->job_count;
    my $jmax = $self->settings->runner->slots_per_job;
    my $srmax = $self->{+CONFIG}->{max_slots_per_run};
    my $sjmax = $self->{+CONFIG}->{max_slots_per_job};

    my $tmin = $task->{min_slots} // 1;
    my $tmax = $task->{max_slots} // $tmin;

    my $max = min($tmax, $sjmax, $srmax, $jmax, $rmax);

    # Invalid condition, minimum is more than our maximim
    return if $tmin > $max;
    $max = $tmin if $max < $tmin;

    return [$tmin, $max];
}

sub available {
    my $self = shift;
    my ($task) = @_;

    my $con = $self->_job_concurrency($task);
    return -1 unless $con;

    my $granted = $self->{+STATE}->allocate_slots(con => $con, job_id => $task->{job_id});

    return unless $granted;

    return $granted
}

sub assign {
    my $self = shift;
    my ($task, $state) = @_;

    return if $self->{+OBSERVE};

    my $info = $self->{+STATE}->assign_slots(
        job => {
            job_id => $task->{job_id},
            file   => $task->{rel_file} // $task->{file} // $task->{job_name},
        },
     );

    $state->{env_vars}->{T2_HARNESS_MY_JOB_CONCURRENCY} = $info->{count};

    return $info;
}

sub record { } # NOOP

sub release {
    my $self = shift;
    my ($job_id) = @_;

    return if $self->{+OBSERVE};

    $self->{+STATE}->release_slots(job_id => $job_id);

    return;
}

sub status_lines {
    my $self = shift;

    my $runners = $self->state->state->{runners};

    my $global_status = {
        todo     => 0,
        allotted  => 0,
        assigned => 0,
        pending  => 0,
    };
    my $details = "";
    for my $runner (sort { $a->{added} <=> $b->{added} } values %$runners) {
        my $run_status = {
            todo     => $runner->{todo},
            allotted  => $runner->{allotment},
            assigned => 0,
            pending  => 0,
        };

        my $jobs = "";
        for my $job (sort { $a->{started} <=> $b->{started} } values %{$runner->{assigned}}) {
            $run_status->{assigned} += $job->{count};
            my $stamp   = $job->{started};
            my $runtime = $stamp ? sprintf("%8.2fs", time - $stamp) : '   --   ';
            my $slots   = sprintf("%-3d", $job->{count});
            $jobs .= "     $runtime | Slots: $slots | " . ($job->{file} // $job->{job_id}) . "\n";
        }

        $run_status->{pending} = $runner->{allotment} - $run_status->{assigned};

        $global_status->{$_} += $run_status->{$_} for keys %$global_status;

        $details .= <<"        EOT";
      ** $runner->{user} - $runner->{name} - $runner->{runner_id} **
            Todo: $run_status->{todo}
        Allotted: $run_status->{allotted}
        Assigned: $run_status->{assigned}
         Pending: $run_status->{pending}

$jobs

        EOT
    }

    $global_status->{total} = $self->state->{max_slots};
    $global_status->{free} = $global_status->{total} - ($global_status->{assigned} + $global_status->{pending});
    $global_status->{free} = "$global_status->{free} (Minimum per-run overrides max slot count in some cases)" if $global_status->{free} < 0;

    my $out = <<"    EOT";
   ** System Wide Summary **
                  TODO: $global_status->{todo}
    Total Shared Slots: $global_status->{total}
 Allotted Shared Slots: $global_status->{allotted}
 Assigned Shared Slots: $global_status->{assigned}
  Pending Shared Slots: $global_status->{pending}
     Free Shared Slots: $global_status->{free}
  ---------------------------

   ** Runners **
$details
    EOT

    return $out;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Runner::Resource::SharedJobSlots - limit the job count (-j) per machine

=head1 SYNOPSIS

B<This synopsis is not about using this in code, but rather how to use it on the command line.>

In order to use SharedJobSlots you must ether create the C<.sharedjobslots.yml>
file, or provide the C<--shared-jobs-config PATH> argument on the command line.
The C<PATH> must be a path to a yaml file with configuration specifications for
job sharing.

=head1 CONFIG FILE

Config files for shared slots must be yaml file, they must also be parsable by
L<YAML::Tiny>, which implements a subset of yaml.

Here is an example config file:

    ---
    DEFAULT:
      state_file: /tmp/yath-slot-state
      max_slots:  8
      max_slots_per_job: 2
      max_slots_per_run: 6

    myhostname:
      state_file: /tmp/myhostname-slot-state
      max_slots:  16
      max_slots_per_job: 4
      max_slots_per_run: 12

=head2 TOP LEVEL KEYS (HOSTNAMES)

All top level keys are hostnames. When the config is read the settings for the
current hostname will be used. If the hostname is not defined then the
C<DEFAULT> host will be read. If there is no C<DEFAULT> host defined an
exception will be thrown.

=head2 CONFIG OPTIONS

Each option must be specified under a hostname, none of these are valid on
their own.

=over 4

=item state_file: /path/to/shared/state/file

B<REQUIRED>

This specifies the path to the shared state file. All yath processes by all
users who are sharing slots need read+write access to this file.

=item state_umask: 0007

Defaults to C<0007>. Used to set the umask of the state file as well as the
lock file.

=item max_slots: 8

Max slots system-wide for all users to share.

=item max_slots_per_run: 4

Max slots a specific test run can use.

=item min_slots_per_run: 0

Minimum slots per run.

Set this if you want to make sure that all runs get at least N slots,
B<EVEN IF IT MEANS GOING OVER THE SYSTEM-WIDE MAXIMUM!>.

This defaults to 0.

=item max_slots_per_job: 2

Max slots a specific test job (test file) can use.

=item algorithm: fair

=item algorithm: first

=item algorithm: Fully::Qualified::Module::function_name

Algorithm to use when assigning slots. 'fair' is the default.

=back

=head3 ALGORITHMS

These are algorithms that are used to decide which test runs get which slots.

=over 4

=item fair

B<DEFAULT>

This algorithm tries to balance slots so that all runs share an equal fraction
of available slots. If there are not enough slots to go around then priority
goes to oldest runs, followed by oldest requests.

=item first

Priority goes to the oldest run, followed by the next oldest, etc. If the run
age is not sufficient to sort requests this will fall back to 'fair'.

This is mainly useful for CI systems or batched test boxes. This will give
priority to the first test run started, so additional test runs will not
consume slots the first run wants to use, but if the first run is winding down
and does not need all the slots, the second test run can start using only the
spare slots.

Use this with ordered test runs where you do not want a purely serial run
order.

=item Fully::Qualified::Module::function_name

You can specify custom algorithms by giving fully qualified subroutine names.

=back

Example custom algorithm:

    sub custom_sort {
        my ($state_object, $state_data, $a, $b) = @_;

        return 1 if a_should_come_first($a, $b);
        return -1 if b_should_come_first($a, $b);
        return 0 if both_have_same_priority($a, $b);

        # *shrug*
        return 0;
    }

Ultimately this is used in a C<sort()> call, usual rules apply, return should
be 1, 0, or -1. $a and $b are the 2 items being compared. $state_object is an
instance of C<Test2::Harness::Runner::Resource::SharedJobSlots::State>.
$state_data is a hashref like you get from C<< $state_object->state() >> which
is useful if you want to know how many slots each runner is using for a 'fair'
style algorth.

Take a look at the C<request_sort_XXX> methods on
C<Test2::Harness::Runner::Resource::SharedJobSlots::State> which implement the
3 original sorting methods.

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2022 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
