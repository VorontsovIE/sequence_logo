require_relative '../../sequence_logo'
require 'fileutils'
require 'tempfile'

def load_alignment_infos(alignment_lines)
  alignment_lines.map{|line|
    filename, shift, orientation, motif_name = line.strip.split("\t")
    motif_name ||= File.basename(filename, File.extname(filename))
    shift = shift.to_i
    orientation = orientation.downcase.to_sym

    ppm = Bioinform::MotifModel::PCM.from_file(filename, validator: Bioinform::MotifModel::PCM::DIFFERENT_COUNTS_VALIDATOR)
    ppm.name ||= motif_name

    raise 'Unknown orientation'  unless [:direct, :revcomp].include?(orientation)

    ppm_oriented = (orientation == :direct) ? ppm : ppm.revcomp
    {motif: ppm_oriented, shift: shift}
  }
end

def make_logo_alignment(aligned_motifs, options)
  alignment = SequenceLogo::Alignment.new
  aligned_motifs.map {|motif_infos|
    ppm_logo = SequenceLogo::PPMLogo.new(motif_infos[:motif],
                                        icd_mode: options[:icd_mode],
                                        enable_threshold_lines: options[:threshold_lines])
    alignment += SequenceLogo::Alignment::Item.new(ppm_logo, motif_infos[:shift])
  }
  alignment
end

def readlines_from_file_or_stdin(argv, from_stdin: , **options)
  default_options = { source_not_given_msg: 'Specify input data',
                      both_sources_given_msg: 'Specify either file with data or data itself in stdin, not both'}
  options = default_options.merge(options)
  raise ArgumentError, options[:both_sources_given_msg]  if from_stdin && !argv.empty?
  raise ArgumentError, options[:source_not_given_msg]  if !from_stdin && argv.empty?
  if from_stdin || argv == ['-']
    $stdin.readlines
  elsif argv.length == 1
    File.readlines(argv.first)
  else
    raise ArgumentError, 'alignment should either be in stdin or in file, specified by arglist'
  end
end

def direct_output_filename(output_file)
  extname = File.extname(output_file)
  basename = File.basename_wo_extname(output_file)
  dirname = File.dirname(output_file)
  File.join(dirname, "#{basename}_direct#{extname}")
end

def reverse_output_filename(output_file)
  extname = File.extname(output_file)
  basename = File.basename_wo_extname(output_file)
  dirname = File.dirname(output_file)
  File.join(dirname, "#{basename}_revcomp#{extname}")
end

begin
  doc = <<-EOS
  Usage:
    glue_logos <output file> <alignment infos file>
      or
    <alignment infos file> | glue_logos <output file> --from-stdin

  Alignment infos has the following format (tab separated)
  if motif names not specified - filenames are used as labels:
    pcm_file_1  shift_1  orientation_1  [motif_name_1]
    pcm_file_2  shift_2  orientation_2  [motif_name_2]
    pcm_file_3  shift_3  orientation_3  [motif_name_3]

  EOS

  argv = ARGV
  total_orientation = :direct
  default_options = { x_unit: 30, y_unit: 60, logo_shift: 300, scheme: 'nucl_simpa',
                      icd_mode: :discrete, threshold_lines: false,
                      text_size: 24, background_color: 'white', from_stdin: false }
  cli = SequenceLogo::CLI.new(default_options)
  cli.instance_eval do
    parser.banner = doc
    parser.on_head('--logo-shift SHIFT', 'Width of region for labels') do |v|
      options[:logo_shift] = v.to_i
    end
    parser.on_head('--text-size SIZE', 'Text size in points') do |v|
      options[:text_size] = v.to_f
    end
    parser.on_head('--orientation ORIENTATION', 'Which logo to draw: direct/revcomp/both') do |v|
      v = v.to_sym
      raise ArgumentError, 'Orientation can be either direct or revcomp or both'  unless [:direct, :revcomp, :both].include?(v)
      total_orientation = v
    end

    parser.on('--bg-fill FILL', 'Background fill. Specify either `transparent` or `color` or `color,hatch_color`') do |v|
      if v.match(/^\w+,\w+$/)
        options[:background_fill] = Magick::HatchFill.new(*v.split(','))
      else
        options[:background_fill] = Magick::SolidFill.new(v)
      end
    end

    parser.on('--from-stdin') do 
      options[:from_stdin] = true
    end
  end
  options = cli.parse_options!(argv)

  output_file = argv.shift
  raise ArgumentError, 'Specify output file'  unless output_file

  alignment_lines = readlines_from_file_or_stdin(argv,  from_stdin: options[:from_stdin],
                                                        source_not_given_msg: 'Specify alignment infos',
                                                        both_sources_given_msg: 'You can specify alignment infos either from file or from stdin. Don\'t use both sources simultaneously')
  alignment = make_logo_alignment(load_alignment_infos(alignment_lines), options)

  scheme_dir = File.join(SequenceLogo::AssetsPath, options[:scheme])
  letter_images = SequenceLogo::CanvasFactory.letter_images(scheme_dir)
  canvas_factory = SequenceLogo::CanvasFactory.new( letter_images, x_unit: options[:x_unit], y_unit: options[:y_unit],
                                                    text_size: options[:text_size], logo_shift: options[:logo_shift],
                                                    background_fill: options[:background_fill] )

  case total_orientation
  when :direct
    alignment.render(canvas_factory).write('PNG:' + output_file)
  when :revcomp
    alignment.revcomp.render(canvas_factory).write('PNG:' + output_file)
  when :both
    alignment.render(canvas_factory).write('PNG:' + direct_output_filename(output_file))
    alignment.revcomp.render(canvas_factory).write('PNG:' + reverse_output_filename(output_file))
  end

rescue => err
  $stderr.puts "\n#{err}\n#{err.backtrace.first(5).join("\n")}\n\nUse --help option for help\n\n#{doc}"
end
