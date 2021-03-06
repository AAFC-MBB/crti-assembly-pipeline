#!/usr/bin/env perl
use warnings;
use strict;
use Getopt::Long;
use 5.010;
use YAML::XS qw(LoadFile DumpFile);
use File::Path;
use File::Basename;
use Assembly::Utils;
use Pod::Usage;

my $fastqc_bin = "/opt/bio/FastQC/fastqc";
my $qsub_bin = "/opt/gridengine/bin/lx26-amd64/qsub";

my $options = {};
my $records = {};
my @qsub_cmd_list;

=head1 NAME

FastQC.pl

=head1 SYNOPSIS

FastQC.pl [--trim|--raw]

=head1 OPTIONS

=over 8

=item B<--yaml_in>

Input YAML file containing samples to process and associated metadata.

=item B<--yaml_out>

Output YAML file with updates from FastQC processing for input into the next stage of processing.

=item B<--raw>

Generate a fastqc report for the raw reads files for each input sample.

=item B<--trim>

Generate a fastqc report for the trimmed reads for each input sample. Requires that trimmed files have previously been generated.

=item B<--sample>

Specify the ID of a single sample to generate the fastqc report for.

=item B<--verbose>

Increase output message detail.

=item B<--testing>

Run through the script but do not create files or directories or submit qsub commands.

=item B<--man>

Report full documentation and exit.

=item B<--help>

Prints out help message and exits.

=item B<--defaults>

Print out the defaul option values and exit.

=back

=head1 DESCRIPTION

Run fastqc to generate reports for all raw reads files for all samples in the input YAML file.

=cut 

sub set_default_opts
{
    my %defaults = ();
    if ($options->{raw}) {
        %defaults = qw(
            yaml_in yaml_files/01_dirsetup.yml
            yaml_out yaml_files/02_rawqc.yml
            qsub_batch_file qsub_files/01_raw_fastqc.sh
            qsub_script qsub_script.sh
            );
    } elsif ($options->{trim}) {
        %defaults = qw(
            yaml_in yaml_files/03_trim.yml
            yaml_out yaml_files/04_trimqc.yml
            qsub_script qsub_script.sh
            qsub_batch_file qsub_files/03_trim_fastqc.sh
            );
    } 
    for my $key (keys %defaults) {
        $options->{$key} = $defaults{$key} unless $options->{$key};
    }
    my $tr = "raw";
    if ($options->{trim}) {
        $tr = "trim";
    }
    my $qopts = " -N " . $tr . "_FastQC ";
    if ($options->{qsub_opts}) {
        $options->{qsub_opts} .= $qopts;
    } else {
        $options->{qsub_opts} = $qopts;
    }
    Assembly::Utils::print_defaults ($0, $options);
}    

sub check_opts
{
    unless ($options->{yaml_in} and $options->{yaml_out} and ($options->{trim} or $options->{raw})) {
        pod2usage(1);
    }
}

sub gather_opts
{
	GetOptions($options,
			'yaml_in|i=s',
			'yaml_out|o=s',
			'raw',
			'trim',
			'sample=s',
			'verbose|v',
			'testing',
			'qsub_opts=s',
			'qsub_script=s',
			'qsub_batch_file=s',
			'man|m',
			'help|h',
			'defaults|d',
			) or pod2usage(1);
	pod2usage(1) if $options->{help};
	pod2usage(-exitval => 0, -verbose => 2) if $options->{man};
	set_default_opts;
	check_opts;
}

sub check_record_fields
{
    my $rec = shift;
    my $rval = shift;
    my $tr = shift;
    my $trdata = shift;
    unless (defined $rec->{sample}) {
        print "No sample for input record! Skipping.\n";
        return 0;
    }
    unless (defined $rec->{sample_dir}) {
        print "No sample_dir specified for sample " . $rec->{sample} . " - skipping\n";
        return 0;
    }
    unless (defined $rec->{$rval}) {
        print "Skipping sample " . $rec->{sample} . " - no data found for direction $rval.\n";
        return 0;
    }
    unless (defined $rec->{$rval}->{$trdata} and (-e $rec->{$rval}->{$trdata})) {
        print "Skipping sample " . $rec->{sample} . " - required $tr data file is missing or nonexistent.\n";
        return 0;
    }
    return 1;
}

sub get_fastqc_subdir
{
    my $rec = shift;
    my $rval = shift;
    my $tr = shift;
    my $tr_filename = shift;
    
    my $sample_dir = Assembly::Utils::get_check_record($rec, ["sample_dir"]);
    $tr_filename =~ s/\.gz\s*$//; # get rid of .gz extension for folder name.
    my $fastqc_subdir = $sample_dir . "/fastqc_out/" . $tr_filename . "_fastqc";
    my $key = $tr . "_subdir";
    #$rec->{fastqc}->{$rval}->{$key} = $fastqc_subdir;
    Assembly::Utils::set_check_record($rec, ["fastqc", $rval], $key, $fastqc_subdir);
    return $fastqc_subdir;
}

sub get_fastqc_cmd
{
    my $rec = shift;
    my $rval = shift;
    my $tr = shift;
    my $trdata = shift;
    my $fastqc_out = shift;
    my $fastqc_cmd = $fastqc_bin . " -o " . $fastqc_out . " " . $rec->{$rval}->{$trdata};
    my $key = $tr . "_cmd";
    #$rec->{fastqc}->{$rval}->{$key} = $fastqc_cmd;
    Assembly::Utils::set_check_record($rec, ["fastqc", $rval], $key, $fastqc_cmd);
    return $fastqc_cmd;
}

sub get_qsub_cmd
{
    my $rec = shift;
    my $rval = shift;
    my $tr = shift;
    my $fastqc_cmd = shift;
    my $qsub_cmd = $qsub_bin . " " . $options->{qsub_opts} . " " . $options->{qsub_script} . " '" . $fastqc_cmd . "'";
    my $key = $tr . "_qsub";
    #$rec->{fastqc}->{$rval}->{$key} = $qsub_cmd;
    Assembly::Utils::set_check_record($rec, ["fastqc", $rval], $key, $qsub_cmd);
    return $qsub_cmd;
}

sub submit_qsub
{
    my $rec = shift;
    my $filename = shift;
    my $fastqc_subdir = shift;
    my $qsub_cmd = shift;
    if (-e $fastqc_subdir) {
        if ($options->{verbose}) {
            print "Won't run fastqc on file $filename - output folder already exists:\n";
            print $fastqc_subdir . "\n";
        }
    } else {
        if ($options->{verbose}) {
            print "Submitting qsub command:\n${qsub_cmd}\n";
            #my $fqcout = ($rec->{fastqc}->{fastqc_out} ? $rec->{fastqc}->{fastqc_out} : '');
            my $fqcout = Assembly::Utils::get_check_record($rec, ["fastqc", "fastqc_out"]);
            print "didn't find the out dir for this one - contents of fastqc_out:\n";
            print `/bin/ls $fqcout` if $fqcout;
        }
        if ($options->{qsub_batch_file}) {
            push (@qsub_cmd_list, $qsub_cmd);
        }
        unless ($options->{testing}) {
            system($qsub_cmd);
        }
    }
}

sub get_sample_record
{
	my $temp = LoadFile($options->{yaml_in});
	my $sample = $options->{sample};
	if (defined $temp->{$sample}) {
		#$records->{$sample} = $temp->{$sample};
		Assembly::Utils::set_check_record($records, [], $sample, $temp->{$sample});
	} else {
		die "Error: could not find a record for specified sample $sample in file " . $options->{yaml_in} . "\n";
	}
}

sub get_reports
{
    my $rec = shift;
    my $rval = shift;
    my $tr = shift;
    my $fastqc_subdir = shift;
    my $html_path = $fastqc_subdir . "/fastqc_report.html";
    my $text_path = $fastqc_subdir . "/fastqc_data.txt";
    my $html_key = $tr . "_report_html";
    my $text_key = $tr . "_data_txt";
    #$rec->{fastqc}->{$rval}->{$html_key} = $html_path;
    #$rec->{fastqc}->{$rval}->{$text_key} = $text_path;
    Assembly::Utils::set_check_record($rec, ["fastqc", $rval], $html_key, $html_path);
    Assembly::Utils::set_check_record($rec, ["fastqc", $rval], $text_key, $text_path);
}

gather_opts;

if ($options->{sample}) {
	get_sample_record;
} else {
	$records = LoadFile($options->{yaml_in});
}

foreach my $sample (keys %{$records})
{  
    my $rec = $records->{$sample};
    foreach my $tr (qw(trim raw)) {
        if ($options->{$tr}) {
        	my $trdata = $tr . "data";
        	if ($tr =~ /raw/) {
        		$trdata = $trdata . "_symlink";
        	}
            #$rec->{fastqc} = {}; #this actually causes a bug: the loss of all previous raw fastqc commands when running with --trim.
            for my $rval (qw(R1 R2)) {
                if (check_record_fields($rec, $rval, $tr, $trdata)) {
                    my $sample_dir = Assembly::Utils::get_check_record($rec, ["sample_dir"]);
                    my $fastqc_out = $sample_dir . "/fastqc_out";
                    #$rec->{fastqc}->{fastqc_out} = $fastqc_out;
                    Assembly::Utils::set_check_record($rec, ["fastqc"], "fastqc_out", $fastqc_out);
                    mkpath $fastqc_out;
                    #$rec->{fastqc}->{$rval} = {}; # same bug as above.
                    my $tr_filename = basename($rec->{$rval}->{$trdata});
                    my $fastqc_subdir = get_fastqc_subdir($rec, $rval, $tr, $tr_filename);
                    get_reports($rec, $rval, $tr, $fastqc_subdir);
                    my $fastqc_cmd = get_fastqc_cmd($rec, $rval, $tr, $trdata, $fastqc_out);
                    my $qsub_cmd = get_qsub_cmd($rec, $rval, $tr, $fastqc_cmd);
                    submit_qsub($rec, $rec->{$rval}->{$trdata}, $fastqc_subdir, $qsub_cmd);
                } else {
                    print "Failed record check for sample $sample direction $rval.\n";
                }
            }
        }
    }
}
        
if ($options->{qsub_batch_file}) {
    open (FQB, '>', $options->{qsub_batch_file}) or die "Error: could not open file " . $options->{qsub_batch_file} . "\n";
    print FQB join("\n", @qsub_cmd_list) . "\n";
    close (FQB);
}

if ($options->{yaml_out}) {
    DumpFile($options->{yaml_out}, $records);
}
    
    
    
    
    
    
       