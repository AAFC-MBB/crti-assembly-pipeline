#!/usr/bin/env perl
use strict;
use warnings;
use Getopt::Long;
use YAML::XS;
use POSIX qw(strftime);
use Assembly::Utils;
use Cwd;

my $options = {};
my @release_headers = qw (Species Strain Sequencing_Types Trim_Raw Release_Version Best_Kmer Best_N50);

sub set_default_opts
{
    my %defaults = qw(
        yaml_in yaml_files/12_velvet_advisor.yml
        yaml_out yaml_files/13_velvet_release.yml
        release_table input_data/Release.tab
        verbose 0
    );
    for my $kdef (keys %defaults) {
        $options->{$kdef} = $defaults{$kdef} unless $options->{$kdef};
    }
}

sub check_opts
{
    unless ($options->{yaml_in} and $options->{yaml_out}) {
        die "Usage: $0 -i <input yaml file> -o <output yaml file> -r <release table>
            Optional:
                --verbose
            ";
    }
}

sub gather_opts
{
    $options->{qsub_opts} = '';
    GetOptions($options,
        'yaml_in|i=s',
        'yaml_out|o=s',
        'release_table|r=s',
        'verbose',
        );
}

sub get_software_versions
{
    my $versions = {};
    $versions->{fastqx} = `fastqc --version`;
    $versions->{fastx_trimmer} = `fastx_trimmer -h | grep FASTX`;
    $versions->{velvetk} = "2012\n";
    $versions->{velveth} = `velveth_31 | grep Version`;
    $versions->{velvetg} = `velvetg_31 | grep Version`;
    return $versions;
}

sub parse_release_table
{
    my $fname = shift;
    my $base_dir = shift;
    my $release_candidates = {};
    unless ($fname) { return; }
    open (RTAB, '<', $fname) or die "Error: couldn't open release table file $fname\n";
    <RTAB>; # skip header
    while (my $line = <RTAB>) {
        chomp $line;
        my @fields = split (/\t/, $line);
        my $num_headers = scalar @release_headers;
        my $num_fields = scalar @fields;
        my $rec = {};
        for (my $i=0; $i<$num_headers; $i++) { 
            my $key = $release_headers[$i];
            my $val = ($fields[$i] ? $fields[$i] : '');
            $rec->{$key} = $val; 
        }
        my $species = Assembly::Utils::format_species_key($rec->{Species});
        my $strain = Assembly::Utils::format_strain_key($rec->{Strain});
        $release_candidates->{$species} = {};
        $release_candidates->{$species}->{$strain} = $rec;
    }
    return $release_candidates;
}

sub get_release_prefix
{
    my $species = shift;
    my $strain = shift;
    my $cand_rec = shift;
    my $yaml_rec = shift;
    
    my $species_abbr = Assembly::Utils::get_check_record($yaml_rec, [$species, "DNA", $strain, "PE", "species_abbr"]);
    my $cand_release_version = $cand_rec->{Release_Version};
    my $release_prefix = $species_abbr . "_" . $strain . "_" . $cand_release_version;
    return $release_prefix;
}

sub release_exists
{
    my $release_dir = shift;
    my $release_prefix = shift;
    
    unless (-e $release_dir) {
        return 0;
    }
    my $release_yaml_file = $release_dir . "/" . $release_prefix . ".yml";
    unless (-e $release_yaml_file and -s $release_yaml_file) {
        # yml file doesn's exist or has size=0
        return 0;
    }
    # check for any other files here ... reads / contigs?
}   

sub get_release_stanza
{
    my $species = shift;
    my $strain = shift;
    my $inrec = shift;
    my $outrec = {};
    $outrec->{species} = Assembly::Utils::get_check_record($inrec, ["PE", "sequencing_metadata", "Organism"]);
    $outrec->{strain} = Assembly::Utils::get_check_record($inrec, ["PE", "sequencing_metadata", "Genotype"]);
    $outrec->{version} = Assembly::Utils::get_check_record($inrec, ["release", "version"]);
    $outrec->{date} = strftime "%m/%d/%Y", localtime;
    return $outrec;
}
    
sub get_genome_stanza
{
    my $species = shift;
    my $strain = shift;
    my $trimraw = shift;
    my $inrec = shift;
    my $release_kmer = shift;
    my $outrec = {};
    $outrec->{species_dir} = Assembly::Utils::get_check_record($inrec, ["PE", "species_dir"]);
    $outrec->{estimated_genome_length} = Assembly::Utils::get_check_record($inrec, ["PE", "related_genome_length", "RG_Est_Genome_Length"]);
    $outrec->{release_kmer} = $release_kmer;
    $outrec->{N50} = Assembly::Utils::get_check_record($inrec, ["velvet", $trimraw, "kmer", $release_kmer, "N50"]);
    $outrec->{max_contig} = Assembly::Utils::get_check_record($inrec, ["velvet", $trimraw, "kmer", $release_kmer, "max_contig"]);
    $outrec->{reads_used} = Assembly::Utils::get_check_record($inrec, ["velvet", $trimraw, "kmer", $release_kmer, "reads_used"]);
    $outrec->{total_length} = Assembly::Utils::get_check_record($inrec, ["velvet", $trimraw, "kmer", $release_kmer, "total_length"]);
    my @types = ();
    for my $st (qw(PE PER MP MP3 MP8)) {
        if (Assembly::Utils::get_check_record($inrec, [$st])) {
            push (@types, $st);
        }
    }
    $outrec->{assembly_sample_types} = join (",", @types);
    return $outrec;
}

sub get_sample_stanza
{
    my $sample_rec = shift;
    my $sample_type = shift;
    my $trimraw = shift;
    my $outrec = {};
    $outrec->{sequencing_metadata} = Assembly::Utils::get_check_record($sample_rec, ["sequencing_metadata"]);
    # $outrec->{species_abbr} = Assembly::Utils::get_check_record($sample_rec, ["species_abbr"]);
    $outrec->{read_data} = {};
    $outrec->{read_data}->{sample_dir} = Assembly::Utils::get_check_record($sample_rec, ["sample_dir"]);
    $outrec->{read_data}->{R1} = {};
    $outrec->{read_data}->{R1}->{raw} = {};
    $outrec->{read_data}->{R1}->{raw}->{file_path} = Assembly::Utils::get_check_record($sample_rec, ["R1", "rawdata"]);
    $outrec->{read_data}->{R1}->{raw}->{num_reads} = Assembly::Utils::get_check_record($sample_rec, ["data_stats", "R1", "rawdata", "num_reads"]);
    $outrec->{read_data}->{R1}->{raw}->{read_length} = Assembly::Utils::get_check_record($sample_rec, ["data_stats", "R1", "rawdata", "read_length"]);
    $outrec->{read_data}->{R2} = {};
    $outrec->{read_data}->{R2}->{raw} = {};
    $outrec->{read_data}->{R2}->{raw}->{file_path} = Assembly::Utils::get_check_record($sample_rec, ["R2", "rawdata"]);
    $outrec->{read_data}->{R2}->{raw}->{num_reads} = Assembly::Utils::get_check_record($sample_rec, ["data_stats", "R2", "rawdata", "num_reads"]);
    $outrec->{read_data}->{R2}->{raw}->{read_length} = Assembly::Utils::get_check_record($sample_rec, ["data_stats", "R2", "rawdata", "read_length"]);

    # get info for output file path for release raw reads
    my $bio_type = Assembly::Utils::get_check_record($sample_rec, ["bio_type"]);
    my $sample_id = Assembly::Utils::get_check_record($sample_rec, ["sample"]);
    my $release_prefix = Assembly::Utils::get_check_record($sample_rec, ["release", "prefix"]);
    my $release_dir = Assembly::Utils::get_check_record($sample_rec, ["release", "release_dir"]);
    my $fpath_base = $release_dir . "/" . $release_prefix . "_" . $bio_type . "_" . $sample_type . 
            "_" . $sample_id . "_";

    my $r1_in = Assembly::Utils::get_check_record($sample_rec, ["R1", "rawdata"]);
    my $r1_out = $fpath_base . "R1.fq";
    my $r2_in = Assembly::Utils::get_check_record($sample_rec, ["R2", "rawdata"]);
    my $r2_out = $fpath_base . "R2.fq";

    $outrec->{release} = [];
    $outrec->{release}->[0] = {};
    $outrec->{release}->[0]->{input_file} = $r1_in;
    $outrec->{release}->[0]->{output_file} = $r1_out;
    $outrec->{release}->[1] = {};
    $outrec->{release}->[1]->{input_file} = $r2_in;
    $outrec->{release}->[1]->{output_file} = $r2_out;

    # copy the files here??
    unless (-e $r1_out and (-s $r1_in) == (-s $r1_out)) {
        #system("cp $r1_in $r1_out");
    }
    unless (-e $r2_out and (-s $r2_in) == (-s $r2_out)) {
        #system("cp $r2_in $r2_out");
    }

    if ($trimraw =~ /trim/) {
        $outrec->{read_data}->{R1}->{trim} = {};
        $outrec->{read_data}->{R1}->{trim}->{file_path} = Assembly::Utils::get_check_record($sample_rec, ["R1", "trimdata"]);
        $outrec->{read_data}->{R1}->{trim}->{num_reads} = Assembly::Utils::get_check_record($sample_rec, ["data_stats", "R1", "trimdata", "num_reads"]);
        $outrec->{read_data}->{R1}->{trim}->{read_length} = Assembly::Utils::get_check_record($sample_rec, ["data_stats", "R1", "trimdata", "read_length"]);
        $outrec->{read_data}->{R2}->{trim} = {};
        $outrec->{read_data}->{R2}->{trim}->{file_path} = Assembly::Utils::get_check_record($sample_rec, ["R2", "trimdata"]);
        $outrec->{read_data}->{R2}->{trim}->{num_reads} = Assembly::Utils::get_check_record($sample_rec, ["data_stats", "R2", "trimdata", "num_reads"]);
        $outrec->{read_data}->{R2}->{trim}->{read_length} = Assembly::Utils::get_check_record($sample_rec, ["data_stats", "R2", "trimdata", "read_length"]);

        my $tr1_in = Assembly::Utils::get_check_record($sample_rec, ["R1", "trimdata"]);
        my $tr1_out = $fpath_base . "R1.fq";
        my $tr2_in = Assembly::Utils::get_check_record($sample_rec, ["R2", "trimdata"]);
        my $tr2_out = $fpath_base . "R2.fq";
        
        $outrec->{release}->[2] = {};
        $outrec->{release}->[2]->{input_file} = $tr1_in;
        $outrec->{release}->[2]->{output_file} = $tr1_out;
        $outrec->{release}->[3] = {};
        $outrec->{release}->[3]->{input_file} = $tr2_in;
        $outrec->{release}->[3]->{output_file} = $tr2_out;
    }
    
    # Now add the fastqc info to the pipeline
    my $qcr1 = {};
    $qcr1->{description} = "FastQC";
    $qcr1->{version} = `fastqc --version`;
    $qcr1->{command} = Assembly::Utils::get_check_record($sample_rec, ["fastqc", "R1", "raw_cmd"]);
    $qcr1->{qsub_cmd} = Assembly::Utils::get_check_record($sample_rec, ["fastqc", "R1", "raw_qsub"]);
    $qcr1->{run_dir} = getcwd;
    
    my $qcr2 = {};
    $qcr2->{description} = "FastQC";
    $qcr2->{version} = `fastqc --version`;
    $qcr2->{command} = Assembly::Utils::get_check_record($sample_rec, ["fastqc", "R2", "raw_cmd"]);
    $qcr2->{qsub_cmd} = Assembly::Utils::get_check_record($sample_rec, ["fastqc", "R2", "raw_qsub"]);
    $qcr2->{run_dir} = getcwd;
    
    my $qtr1 = {};
    $qtr1->{description} = "Fastx_trimmer";
    $qtr1->{version} = `fastx_trimmer -h | grep FASTX`;
    $qtr1->{command} = Assembly::Utils::get_check_record($sample_rec, ["fastx_trimmer", "R1", "trim_cmd"]);
    $qtr1->{qsub_cmd} = Assembly::Utils::get_check_record($sample_rec, ["fastx_trimmer", "R1", "qsub_cmd"]);
    $qtr1->{run_dir} = getcwd;
    
    my $qtr2 = {};
    $qtr2->{description} = "Fastx_trimmer";
    $qtr2->{version} = `fastx_trimmer -h | grep FASTX`;
    $qtr2->{command} = Assembly::Utils::get_check_record($sample_rec, ["fastx_trimmer", "R2", "trim_cmd"]);
    $qtr2->{qsub_cmd} = Assembly::Utils::get_check_record($sample_rec, ["fastx_trimmer", "R2", "qsub_cmd"]);
    $qtr2->{run_dir} = getcwd;    
    
    # Now add the fastqc info to the pipeline
    my $qct1 = {};
    $qct1->{description} = "FastQC";
    $qct1->{version} = `fastqc --version`;
    $qct1->{command} = Assembly::Utils::get_check_record($sample_rec, ["fastqc", "R1", "trim_cmd"]);
    $qct1->{qsub_cmd} = Assembly::Utils::get_check_record($sample_rec, ["fastqc", "R1", "trim_qsub"]);
    $qct1->{run_dir} = getcwd;
    
    my $qct2 = {};
    $qct2->{description} = "FastQC";
    $qct2->{version} = `fastqc --version`;
    $qct2->{command} = Assembly::Utils::get_check_record($sample_rec, ["fastqc", "R2", "trim_cmd"]);
    $qct2->{qsub_cmd} = Assembly::Utils::get_check_record($sample_rec, ["fastqc", "R2", "trim_qsub"]);
    $qct2->{run_dir} = getcwd;
    
    my $qc =[];
    push (@$qc, $qcr1);
    push (@$qc, $qcr2);
    if ($trimraw =~ /trim/) {
        push (@$qc, $qtr1);
        push (@$qc, $qtr2);
        push (@$qc, $qct1);
        push (@$qc, $qct2);
    }
    return ($outrec, $qc);
}

sub get_pipeline_stanza
{
    my $strain_rec = shift;
    my $trimraw = shift;
    my $release_kmer = shift;
    my $release_dir = shift;
    my $release_prefix = shift;
    my $outrec = []; # note: it's an array this time
    my $krec = Assembly::Utils::get_check_record($strain_rec, ["velvet", $trimraw, "kmer", $release_kmer]);
    
    my $vh = {};
    $vh->{description} = "velveth";
    $vh->{run_dir} = getcwd;
    $vh->{version} = `velveth_31 | grep Version`;
    $vh->{command} = Assembly::Utils::get_check_record($krec, ["velveth_cmd"]);
    $vh->{qsub_cmd} = Assembly::Utils::get_check_record($krec, ["velveth_qsub_cmd"]);
    
    my $vg = {};
    $vg->{description} = "velvetg";
    $vg->{run_dir} = getcwd;
    $vg->{version} = `velvetg_31 | grep Version`;
    $vg->{command} = Assembly::Utils::get_check_record($krec, ["velvetg_cmd"]);
    $vg->{qsub_cmd} = Assembly::Utils::get_check_record($krec, ["velvetg_qsub_cmd"]);
    my $kmer_dir = Assembly::Utils::get_check_record($krec, ["kmer_dir"]);
    my $contigs_infile = $kmer_dir . "/contigs.fa";
    my $contigs_outfile = $release_dir . "/" . $release_prefix . "_contigs.fa";
    $vg->{release} = [];
    $vg->{release}->[0] = {};
    $vg->{release}->[0]->{input_file} = $contigs_infile;
    $vg->{release}->[0]->{output_file} = $contigs_outfile;
}   

sub create_release_yaml
{
    my $species = shift;
    my $strain = shift;
    my $cand_rec = shift;
    my $strain_rec = shift;
    my $release_yaml_rec = {};
    my $trimraw = $cand_rec->{Trim_Raw};
    my $release_kmer = $cand_rec->{Best_Kmer};
    
    $release_yaml_rec->{release} = get_release_stanza($species, $strain, $strain_rec);
    $release_yaml_rec->{genome_assembly} = get_genome_stanza($species, $strain, $trimraw, $strain_rec, $release_kmer);
    my $pipeline = [];
    for my $sample_type (qw(PE PER MP MP3 MP8)) {
        my $sample_rec = Assembly::Utils::get_check_record($strain_rec, [$sample_type]);
        if ($sample_rec) {
            my ($sample_stanza, $qc_cmds) = get_sample_stanza($sample_rec, $sample_type);
            $release_yaml_rec->{$sample_type} = $sample_stanza;
            for my $rec (@$qc_cmds) {
                push (@$pipeline, $rec);
            }
        }
    }
    # Now get the rest of the pipeline
    my $pipeline_remainder = get_pipeline_stanza($strain_rec, $trimraw);
    for my $rec (@$pipeline_remainder) {
        push (@$pipeline, $rec);
    }
    $release_yaml_rec->{pipeline} = $pipeline;
    return $release_yaml_rec;
}

sub create_release
{
    my $species = shift;
    my $strain = shift;
    my $cand_rec = shift;
    my $yaml_rec = shift;
    
    my $release_prefix = get_release_prefix($species, $strain, $cand_rec, $yaml_rec);
    my $species_dir = Assembly::Utils::get_check_record($yaml_rec, ["PE", "species_dir"]);
    my $release_dir = $species_dir . "/release/" . $release_prefix;
    Assembly::Utils::set_check_record($yaml_rec, ["release"], "prefix", $release_prefix);
    Assembly::Utils::set_check_record($yaml_rec, ["release"], "release_dir", $release_dir);
    Assembly::Utils::set_check_record($yaml_rec, ["release"], "version", $cand_rec->{Release_Version});
    unless (release_exists($release_dir, $release_prefix)) {
        mkpath $release_dir;
        my $release_yaml_fname = $release_dir . "/" . $release_prefix . ".yml";
        Assembly::Utils::set_check_record($yaml_rec, ["release"], "yaml_file", $release_yaml_fname);
        my $trimraw = $cand_rec->{Trim_Raw};
        my $release = create_release_yaml($species, $strain, $cand_rec, $yaml_rec);
        #DumpFile($release_yaml_fname, $release);
        # add yml info to release yml record
        # write the release yml record
        # copy over the required files
    }
}

sub create_all_releases
{
    my $release_candidates = shift;
    my $records = shift;
    for my $species (keys %$records) {
        for my $strain (keys %{$records->{$species}->{DNA}}) {
            my $cand_rec = Assembly::Utils::get_check_record($release_candidates, [$species, $strain]);
            if ($cand_rec) {
                my $yaml_rec = Assembly::Utils::get_check_record($records, [$species, "DNA", $strain]);
                create_release ($species, $strain, $cand_rec, $yaml_rec);
            }
        }
    }
}
        

gather_opts;
my $release_candidates = parse_release_table($options->{release_table});
my $records = LoadFile($options->{yaml_in});
create_all_releases($release_candidates, $records);
DumpFile($options->{yaml_out}, $records);

