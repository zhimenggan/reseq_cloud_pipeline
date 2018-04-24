#!/opt/bio/perl/bin/perl -w

use strict;
use Getopt::Long;
use File::Basename;
use PerlIO::gzip;
use FindBin '$Bin';
use GBCloud;
use AutoRun;

die $! if @ARGV < 1;

## decode json ##
my $obj = get_json(@ARGV);
my $input = $obj->{input};
my $config = $obj->{config};
my $output = $obj->{output};

## get output ##
my ($outdir, $shdir, $reportdir, $jsondir) = get_output($output);

## get config ##
my ($main_paras, $soft_paras) = get_config($config);

## init out_json ##
my $out_json;

my $time = q{`date +%F'  '%H:%M`};
my (%jobs, %run_jobs);

################# above this line is settled code #################

# must set the total_step of the module
my ($step, $total_step) = (0, 3);

# generate shell script for each step
my ($seqType, $qualSys, $outType);
foreach my $sample(keys %{$input->{rawdata_multiple_lanes}}){
	my $ad1 = ( defined $main_paras->{adapter1} ) ? $main_paras->{adapter1} : "";
	my $ad2 = ( defined $main_paras->{adapter2} ) ? $main_paras->{adapter2} : "";
	$ad1 = ( $ad1 =~ /^\s*$/) ? "" : " -f $ad1 ";
	$ad2 = ( $ad2 =~ /^\s*$/) ? "" : " -r $ad2 ";
	`mkdir -p $outdir/$sample`;
	open LIST,">$outdir/$sample/$sample.stat.list"or die "open LIST failed $!\n";
	foreach my $lane(keys %{$input->{rawdata_multiple_lanes}->{$sample}} ){
		($seqType, $qualSys) = &check_seqType("$input->{rawdata_multiple_lanes}->{$sample}->{$lane}->[0]");
		$outType = ($seqType == 1) ? 1 : 0;
		`mkdir -p $outdir/$sample/$lane`;
		open SH,">$shdir/filter.$sample.$lane.sh" or die"cant open SH to write";
		print SH<<END;
echo start filter $sample $lane at $time && \\
export LD_LIBRARY_PATH=/opt/bio/local/lib:\$LD_LIBRARY_PATH && \\
$Bin/$config->{software}->{'soapnuke filter'}->{cmd} $soft_paras->{'soapnuke filter'} -i -Q $qualSys -5 $seqType -7 $outType -G -1 $input->{rawdata_multiple_lanes}->{$sample}->{$lane}->[0] -2 $input->{rawdata_multiple_lanes}->{$sample}->{$lane}->[1] $ad1 $ad2 -o $outdir/$sample/$lane -C $sample.${lane}_1.fq -D $sample.${lane}_2.fq && \\
$Bin/fqcheck33 -r $outdir/$sample/$lane/$sample.${lane}_1.fq.gz -c $outdir/$sample/$lane/$sample.${lane}_1.fqcheck && \\
$Bin/fqcheck33 -r $outdir/$sample/$lane/$sample.${lane}_2.fq.gz -c $outdir/$sample/$lane/$sample.${lane}_2.fqcheck && \\
perl $Bin/fqcheck_distribute.pl $outdir/$sample/$lane/$sample.${lane}_1.fqcheck $outdir/$sample/$lane/$sample.${lane}_2.fqcheck -o $outdir/$sample/$lane/$sample.${lane}. && \\
perl $Bin/soapnuke_stat.pl $outdir/$sample/$lane/Basic_Statistics_of_Sequencing_Quality.txt $outdir/$sample/$lane/Statistics_of_Filtered_Reads.txt > $outdir/$sample/$lane/$lane.stat && \\
echo finish filter $sample $lane at $time && \\
echo finish &> $shdir/filter.$sample.$lane.sh.ok
END
		close SH;
		$jobs{"$shdir/filter.$sample.$lane.sh"} = 1;
		print LIST<<END;
$outdir/$sample/$lane/$lane.stat
END
		# push some file into out_json for the next module
		$out_json->{result}->{clean_data_multiple_lanes}->{$sample}->{$lane} = ["$outdir/$sample/$lane/$sample.${lane}_1.fq.gz", "$outdir/$sample/$lane/$sample.${lane}_2.fq.gz"];
	}
	close LIST;
}

# auto run function for each step
# main_paras->{run} is auto run flag; 'FALSE' means only generate script; 'TRUE' means auto run the module
if($main_paras->{run} eq "TRUE"){
	# count the step
	$step += 1;
	# shdir, %jobs, %run_jobs, step, total_step, vf, threads, project_id, project_version, module_name
	# only modify the 'vf', 'threads' and 'module_name'
	run_cloud($shdir, \%jobs, \%run_jobs, $step, $total_step, "2G", 1, $main_paras->{project_id}, $main_paras->{project_version}, "filter");
}


# step 2:
my ($stat_samples, $stat_files);
foreach my $sample(keys %{$input->{rawdata_multiple_lanes}}){
	open SH,">$shdir/filter.$sample.stat.sh";
	print SH<<END;
echo start filter_stat $sample at $time && \\
perl $Bin/merge_lane_stat.pl $outdir/$sample/$sample.stat.list $outdir/$sample/$sample.xls && \\
perl $Bin/QC.pl --filter_stat $outdir/$sample/$sample.xls --sample $sample --svg $outdir/$sample/$sample.rawdataQC.svg && \\
echo finish filter $sample stat at $time && \\
echo finish &> $shdir/filter.$sample.stat.sh.ok
END
	close SH;
	$jobs{"$shdir/filter.$sample.stat.sh"} = 1;
	$stat_samples .= ",$sample";
	$stat_files   .= ",$outdir/$sample/$sample.xls";
}

if($main_paras->{run} eq "TRUE"){
	$step += 1;
	# shdir, %jobs, %run_jobs, step, total_step, vf, num_proc, project_id, project_version, module_name
	run_cloud($shdir, \%jobs, \%run_jobs, $step, $total_step, "1G", 1, $main_paras->{project_id}, $main_paras->{project_version}, "filter");
}

# step 3:
$stat_samples =~ s/^,//g;
$stat_files =~ s/^,//g;
open SH, ">$shdir/filter_stat.sh";
print SH<<END;
echo start filter stat at $time && \\
$Bin/filter_summary.pl --infiles $stat_files --samples $stat_samples --outfile $outdir/filter_stat.xls && \\
cp $outdir/*/*.png $outdir/*/*.svg $outdir/filter_stat.xls $reportdir/ && \\
echo finish at $time && \\
echo finish &> $shdir/filter_stat.sh.ok
END
close SH;
$jobs{"$shdir/filter_stat.sh"} = 1;
if($main_paras->{run} eq "TRUE"){
	$step += 1;
	run_cloud($shdir, \%jobs, \%run_jobs, $step, $total_step, "1G", 1, $main_paras->{project_id}, $main_paras->{project_version}, "exome_filter");
}

## generate out json file ##
generate_json($out_json, "$jsondir/filter.json");

sub check_seqType{
	my ($fastq) = @_;
	my ($base_count,$line_count,$seqType,$qualSys,$mean_quality) = (0,0,0,0,0);
	open IN,"<:gzip", $fastq;
	while(<IN>){
		chomp;
		$line_count += 1;
		if($line_count % 4 == 1){
			if($_ =~ /\/\d$/){
				$seqType = 0;
			}
			else{
				$seqType = 1;
			}
		}
		elsif($line_count % 4 == 0){
			my @tmp = split(//, $_);
			for my $base(@tmp){
				next if ($base eq "!");
				$base_count += 1;
				$mean_quality += ord($base) - 33;
			}
		}
		last if ($base_count >= 10000);
	}
	close IN;
#	print STDERR "base count:$base_count\n";
	$mean_quality = $mean_quality / $base_count;
	if($mean_quality > 12 && $mean_quality < 43){
		$qualSys = 2;
	}
	else{
		$qualSys = 1;
	}
	return ($seqType, $qualSys);
}
