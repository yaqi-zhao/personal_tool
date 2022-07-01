#
# edp.rb - EMON Data Processor
#
#   @author Zhidong Yu (zhidong.yu@intel.com)
#   @author Pushkaraj Dande (pushkaraj.dande@intel.com)
#
# Copyright (C) 2012, Intel Corporation
# All rights reserved
#
# INTEL CONFIDENTIAL
#

require 'optparse'
require 'thread'
require "rexml/document"

EDP_VERSION = "4.21"

$per_txn_metrics = Hash.new

#
# A class that holds all the command line options
#
class Options
  
  def initialize
   parse_options
  end

  def pare_integer_or_timestamp(str)
    result = nil
    if str && str.is_a?(String)
      if /^-?\d+$/.match(str)
        result = Integer(str)
      elsif /(\d+)\/(\d+)\/(\d+) (\d+):(\d+):(\d+)\.?(\d*)/.match(str)
        month, day, year, hour, min, sec, msec = $1, $2, $3, $4, $5, $6, $7
        usec = '' + msec + '000'   #user may not specify msec. in such case msec is nil.
        result = Time.local(year, month, day, hour, min, sec, usec)
      end
    end
    return result
  end

	
  # parse the options from ARGV
  def parse_options
    opts = OptionParser.new do |opts|
      opts.banner = "Usage: edp.rb [options]\n  ver: #{EDP_VERSION}"
      opts.program_name = "EDP"
      opts.version = EDP_VERSION
      opts.separator "\nRequired options:"
      opts.on("-i", "--input <emon.dat>", "input file: emon dat") { |file| @input_file = file }
      opts.on("-j", "--emonv <emon-v.dat>", "input file: emon -v dat") { |file| @emonv_file = file }
      opts.on("-k", "--emonm <emon-m.dat>", "input file: emon -M dat") { |file| @emonm_file = file }
	  opts.on("-g", "--config <config.xlsx>", "input file: system configuration file") { |file| @config_file = file }
	  opts.on("-d", "--dmidecode <dmidecode.txt>", "input file: dmidecode file") { |file| @dmidecode_file = file }
	  opts.on("-n", "--NetworkStat <networkstat.txt>", "input file: networkstat file") { |file| @networkstat_file = file }
	  opts.on("-D", "--DiskStat <diskstat.txt>", "input file: DiskStat file") { |file| @diskstat_file = file }
      opts.on("-m", "--metric <metric.xml>", "input file: metric definition file") { |file| @formula_file = file }
      opts.on("-f", "--format <format.txt>", "input file: format definition file") { |file| @chart_format = file }
      opts.on("-o", "--output <output.xlsx>", "output file name") { |file| @output_file = file }
      opts.separator "\nOptional options:"
      opts.on("-c", "--frequency FREQUENCY", Float, "TSC frequency in MHz. e.g., -c 1600") { |tsc_freq| @tsc_freq = tsc_freq * 1_000_000 }
      opts.on("-t", "--interval INTERVAL", Float, "Sampling interval in second. e.g., -t 0.2") { |interval| @sampling_interval = interval }
      opts.on("--normalize TIME", Float, "Normalize to events per TIME instead of events per second. Units of TIME is seconds, e.g., --normalize 0.1") { |norm_interval| @normalization_interval = norm_interval }
      opts.on("-q", "--qpi FREQUENCY", Float, "QPI frequency in GT/s. e.g., -q 6.4") { |qpi_freq| @qpi_freq = qpi_freq * 1_000_000_000;  }
      opts.on("-p", "--parallel PARALLEL", Integer, "# of parallel tasks") { |parallel| @parallel = parallel }
      opts.on("-s", "--step STEP", Integer, "step #") { |n| @step = n; }
      opts.on("-b", "--begin #SAMPLE or Timestamp", "begin sample # or timestamp (mm/dd/yyyy hh:mm:ss.xxx) .xxx is milli-second and is optional.") { |n| @average_begin = pare_integer_or_timestamp(n) }
      opts.on("-e", "--end #SAMPLE or Timestamp", "end sample # or timestamp (mm/dd/yyyy hh:mm:ss.xxx) .xxx is milli-second and is optional.") { |n| @average_end = pare_integer_or_timestamp(n) }
      opts.on("-x", "--tps #TPS", Float, "transactions per second") {|tps| @tps = tps }
      opts.on("--socket-view", "generate socket level summary") { @socket_view = true }
      opts.on("--core-view", "generate core level summary") { @core_view = true }
      opts.on("--thread-view", "generate thread level summary") { @thread_view = true }
      opts.on("--atom-tsc-wa", "atom tsc issue workaround") { @atom_tsc_wa = true}
      opts.on("--arm-tsc-multiplier #MULTIPLIER", Float, "arm tsc issue workaround") { |n| @arm_tsc_multiplier = n}
      opts.on("--showaverage", "show average value in output") { @show_average = true}
      opts.on("--timestamp-in-chart", "show average value in output") { @timestamp_in_chart = true}
      opts.on("--temp-dir #DIR", String , "the temporary directory for the intermediate CSV files") { |dir| @temp_dir = dir }
      opts.on("-v", "--verbose", "verbose output to console (not to the output file)") { @verbose = true; }
      opts.separator "\nMisc options:"
      opts.on("-h", "--help", "Show this message") { $stdout.puts opts; exit }
      opts.on("--version", "Show version") { $stdout.puts opts.ver; exit}
	  @supportFilesFlag=0
	  @supportVFlag=0
    end
	
    if ARGV.size==0
      $stdout.puts opts
      exit
    else
      opts.parse!(ARGV)
    end

    if !@temp_dir.nil?
      if File.directory?(@temp_dir)
        @temp_dir = File.expand_path(@temp_dir)
        @temp_dir += File::SEPARATOR
      else
        $stdout.puts " ERROR: #{@temp_dir} is not a valid directory."
        exit
      end
    end

  end

  # an alternative to define attribute reader for every possible attribute
  def method_missing(key)
    eval("@"+key.to_s) if instance_variables.include?("@#{key.to_s}".to_sym) || instance_variables.include?("@#{key.to_s}")
  end
end

#
# System topology and information
#
class Topology
	
  def initialize(options)
  
	 
    @cha_count=0
    @tsc_freq = options.tsc_freq
    @qpi_freq = options.qpi_freq
	@numSamples=0
	@sampling_time=0
	supportFilesFlag=options.supportFilesFlag
	supportVFlag=options.supportVFlag
	emonM=options.emonm_file
	emonV=options.emonv_file
	
	
	if emonV.nil? or emonV.include? "-k"
		#puts"emonV file is null "
		supportVFlag=1
		emonV="emon-v.dat"
	end
	if supportVFlag==1
		
		emonVfile = File.open(emonV, "w")
		
	end
	parse_cha(options.input_file,emonV,emonVfile,supportVFlag)
	  
    if options.emonm_file.nil? 	 
	  supportFilesFlag=1 
	  emonM="emon-m.dat"
	end  
    if supportFilesFlag == 1
		
		emonMfile = File.open(emonM, "w")
	end
	parse_emon_dat(options.input_file, emonM,emonMfile,supportFilesFlag)
	
	$emon_v_file=emonV
	$emon_m_file=emonM
	
	if @sockets[0][0].size == 1
		@hyperThreading = false
	else
		@hyperThreading = true
	end	
	
    if @tsc_freq.nil?
      $stderr.puts " ERROR: TSC Frequency cannot be detected from emon-v and emon data. Please specify it in command line by -c or collect emon data with -v command "
      exit
    end
	if @cha_count==0
	$stderr.puts " ERROR: CHA count cannot be detected, certain memory metrics will not be dispalyed. Please ensure collection of UNC_CHA_CLOCKTICKS"
	end
    $stdout.puts "\n System information:"
	# $stdout.puts "Hyperyhreading #{@hyperThreading}"
    $stdout.puts "     CPU topology: #{@sockets.size} sockets; #{@sockets[0].size} cores/socket; #{@sockets[0][0].size} threads/core; totally #{@cpus.size} CPUs."
    $stdout.puts "     TSC frequency: #{(@tsc_freq/1_000_000).to_i} MHz"
    $stdout.puts "     QPI frequency: #{@qpi_freq/1_000_000_000} GT/s" if @qpi_freq
  end
  
  

  class Hash < ::Hash
    def ids
      keys.sort
    end
  end

  #
  # representing a thread/CPU
  #
  class CpuInfo
    def initialize(cpu, processor, core, thread, cpu_index)
      @cpu_id, @processor_id, @core_id, @thread_id, @cpu_index = cpu, processor, core, thread, cpu_index
    end
    attr_accessor :core_id
    attr_reader :cpu_id, :processor_id, :thread_id, :cpu_index
  end

  #
  # representing a core
  #
  class Core < Hash
    def initialize
      @cpus = Hash.new
    end
    attr_accessor :cpus
    def threads
      self
    end
  end

  #
  # representing a processor
  #
  class Processor < Hash
    def initialize
      @cpus = Hash.new
    end
    attr_accessor :cpus
    def cores
      self
    end
  end

  # parse the emon.dat data to get CPU toptology information
  def parse_emon_dat(file,file2,emonMfile,supportFilesFlag)
    
	if file.nil?
      $stderr.puts " ERROR: emon.dat file must be specified."
      exit
    end
    unless File.exist?(file)
      $stderr.puts " ERROR: The emon.dat file #{file} does not exist."
      exit
    end
	
	
    @cpus = Hash.new
    @sockets = Hash.new
    _phy_to_v_core = Hash.new
    _thread_ids = Hash.new
    _processor_ids = Hash.new
    _cpu_index = 0
	@socket_count=0
	processor_list=Array.new
	flag =0
	
	
	

	  File.open(file) do |f|
      f.each_line do |line|
		
        if line.include? "OS Processor" and flag==0
			
			flag=1 
		end 
		
		if flag==1 and supportFilesFlag==1
			emonMfile.write(line)
		end
		
		if line.include? "Version Info" 
			
			break
		end
				  
      end
      end

	
	if flag==0 and supportFilesFlag==0
		file=file2
		puts "\n Cannot find topology in emon data, searching in emon -M file"
	$stderr.puts "\n WARNING: Support for emon-v and emon-M files is deprecated. Please collect EMON data with -v flag (like emon -v -i clx-2s-events.txt) in future \n"
	elsif flag ==0 and supportFilesFlag==1 
		puts "\n Cannot find topology in emon data and emon support file"
		emonMfile.write("Cannot find topology in emon.dat, please collect emon with -v flag or use appropriate emon-m file in process.cmd")
		exit
	end
	
	if !emonMfile.nil?  
	emonMfile.close  
	end
	
    File.readlines(file).each do |line|
      fields = /^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)/.match(line)
      if fields
        cpu, processor, core, thread = *fields[1..-1].collect{|x| x.to_i}
		processor_list.push(processor)
	
		
        # Record socket id and thread id for sorting later
        if _thread_ids[thread].nil?
            _thread_ids[thread] = thread
        end
        if _processor_ids[processor].nil?
            _processor_ids[processor] = processor
        end

        if @sockets[processor].nil?
          @sockets[processor] = Processor.new
        end
        if @sockets[processor][core].nil?
          @sockets[processor][core] = Core.new
        end
        if @sockets[processor][core][thread].nil?
          cpuinfo = CpuInfo.new(cpu, processor, core, thread, _cpu_index)
	  _cpu_index += 1
          self.sockets[processor][core][thread] = cpuinfo
          self.sockets[processor][core].cpus[cpu] = cpuinfo
          self.sockets[processor].cpus[cpu] = cpuinfo
          self.cpus[cpu] = cpuinfo
        else
          $stderr.puts " ERROR: the emon -M file seems to be invalid."
          exit
        end
      end
    end
    _processor_ids.each_value do |p_id|
        _thread_ids.each_value do |t_id|
            _core_id = 0
            Hash[@cpus.select {|k,v| v.processor_id == p_id and v.thread_id == t_id}].each_value do |core|
                if _phy_to_v_core[p_id].nil?
                    _phy_to_v_core[p_id] = Processor.new
                end
                if _phy_to_v_core[p_id][core.core_id].nil?
                    _phy_to_v_core[p_id][core.core_id] = _core_id
                end
                core.core_id = _core_id
                _core_id += 1
            end
        end
    end
    self.sockets.ids.each do |s_id|
      raise "socket#{s_id} has some core(s) with one thread disable" if _phy_to_v_core[s_id].values.uniq.count != _phy_to_v_core[s_id].count
      self.sockets[s_id].keys.each do |k|
        if _phy_to_v_core[s_id][k].nil?
          raise "something went wrong when mapping cores"
	else
          self.sockets[s_id][_phy_to_v_core[s_id][k]] = sockets[s_id].delete(k)
	end
      end
    end
	
	
	@socket_count=processor_list.max + 1
	
  end

  # parse the emon -v data to get CPU information
  def parse_emon_v(file, emonV, emonVfile, tscFlag, supportVFlag)
    if @tsc_freq.nil?
      if file.nil?
        $stderr.puts " ERROR: emon.dat file must be specified."
        exit
      end
      unless File.exist?(file)
        $stderr.puts " ERROR: The emon file #{file} does not exist."
        exit
      end
    end

    File.open(emonV) do |f|
      f.each_line do |line|
		
		case line
        when /^TSC Freq\D*(\d+)/
          if @tsc_freq.nil?
			puts "In emonv: found TSC freq---"
            @tsc_freq = $1.to_f * 1_000_000
			#puts "********* tsc = #{@tsc_freq} "
          else
            # if @tsc_freq is not nil, it means user specified one in command line.
            $stderr.puts " WARNING: User specified a TSC frequency #{@tsc_freq} to override the TSC frequency #{$1} detected from emon -v data."
          end
        when /----------/
          break
        when /==========/
          break
        end
		
		
      end
    end
  end
  
  def parse_cha(file,emonV,emonVfile,supportVFlag)
  
	columns=Array.new
	chaFlag=0
	tscFlag=0
	writeflag=1
	
	if file.nil?
        $stderr.puts " ERROR: emon.dat file must be specified."
        exit
      end
      unless File.exist?(file)
        $stderr.puts " ERROR: The emon.dat file #{file} does not exist."
        exit
     end
	 
	 
	File.open(file) do |f|
    f.each_line do |line|
	
	case line
		when /cpu_family.*AMD/
          $is_AMD = true
        when /cpu_family.*ARM/
          $is_ARM = true
	end 
	
	if line.include? "UNC_CHA_CLOCKTICKS" and chaFlag==0
		
		columns=line.split(" ")
		@cha_count= columns.count-2
		#ignore first two values as thr 1st is name of counter and 2nd is repeated counter (cycles probably)
		puts " #{@cha_count} CHAs present in the system"
		chaFlag=1
		
	elsif line.include? "TSC Freq"
	
		if(@tsc_freq.nil?)
			if (line.match?(/^TSC Freq\D*(\d+)/))
				columns=line.match(/^TSC Freq\D*(\d+)/)
				@tsc_freq = columns[1].to_f * 1_000_000
				#puts("found match tsc freq #{@tsc_freq}")
			end
		end
		tscFlag=1
	
	elsif line.include? "OS Processor" 
		writeflag=0
		
	elsif supportVFlag==1 and writeflag==1
		emonVfile.write(line)
		
	elsif (tscFlag==1 and chaFlag==1)
		break
	end
		 
		end
    end 
	
	#if TSC Freq is not found in emon.dat, we parse emon.v file 
	if tscFlag==0 and supportVFlag==0
	puts"could not find tsc freq in emon.dat, searching in emon-v"
	parse_emon_v(file, emonV, emonVfile, tscFlag, supportVFlag)
	$stderr.puts "\n WARNING: Support for emon-v and emon-M files is deprecated. Please collect EMON data with -v flag (like emon -v -i clx-2s-events.txt) in future \n"	
	end
	if tscFlag==0 and supportVFlag==1
		puts " Could not find TSC Freq in emon data file and emon-v file is not specified"
		exit
	end	
		
	
  end
  
  #@numSamples=$processed_samples
  #@sampling_time=$samplingTime
  attr_reader :cpus, :sockets, :tsc_freq, :qpi_freq, :cha_count, :socket_count, :numSamples, :sampling_time
  attr_accessor :emonV, :emonM, :numSamples, :sampling_time
end

#
# re-open the Array class to add some statistics functions
#
class Array
  def keep_numbers_only
    self.collect { |x| (x.class==Float && x.nan?) ? nil : x }.compact
  end

  alias original_min min
  def min
    self.keep_numbers_only.original_min
  end

  alias original_max max
  def max
    self.keep_numbers_only.compact.original_max
  end

  # sum of an array of numbers
  def sum
    inject(0){|acc,i| acc + i.to_f }
  end

  # average of an array of numbers
  def average
    sum/length
  end

  # variance of an array of numbers
  # same as the stdevp in Excel
  def sample_variance
    avg=average
    sum=inject(0){|acc,i| acc+(i.to_f-avg)**2}
    1/length.to_f*sum
  end

  # standard deviation of an array of numbers
  def stdev
    tmp = sample_variance
    if tmp.nan? || tmp.infinite?
      tmp
    else
      Math.sqrt(sample_variance)
    end
  end

  # 95 percentile
  def max_95p
    sorted = self.keep_numbers_only.sort
    subset = sorted[0..(sorted.size*0.95).to_i]
    subset.max
  end
end

#
# representing the XML formulas file.
#
class Formulas
  def initialize(options, system)
    @options = options
    @system = system
    @formulas = parse_formulas(options.formula_file)
  end

  #
  # representing a metric's formula
  #
  class Formula
    #                   name: metric name (String)
    #                 events: a Hash of alias => event name
    #              constants: a Hash of alias => constant name
    #                formula: formula (String)
    # per_processor_formulas: an Array of formulas (String)
    attr_accessor :name, :events, :constants, :formula, :per_processor_formulas, :formula_id, :per_txn_metric_name

    def initialize
      @events = Hash.new
      @constants = Hash.new
      @per_processor_formulas = Array.new
    end
  end

  # parse formulas from XML file
  def parse_formulas(file)
    if file.nil?
      $stderr.puts " ERROR: formula definition file must be specified."
      exit
    end
    unless File.file?(file)
      $stderr.puts " ERROR: the metrics definition file #{file} does not exist."
      exit
    end
#    formula_id = 0
    begin
      formulas = Array.new
      doc = REXML::Document.new(File.new(file))
      doc.elements.each("root/metric") do |element|
        f = Formula.new
#        formula_id += 1
#        f.formula_id = formula_id
        
#        method_system = "def metric_system_#{formula_id};"
#        method_socket = "def metric_socket_#{formula_id};"
#        method_core = "def metric_core_#{formula_id};"
#        method_thread = "def metric_thread_#{formula_id};"

        f.name = element.attributes["name"]
#        method_system.concat("metric_name = \"#{f.name}\";")
#        method_socket.concat("metric_name = \"#{f.name}\";")
#        method_core.concat("metric_name = \"#{f.name}\";")
#        method_thread.concat("metric_name = \"#{f.name}\";")

        element.elements.each("throughput-metric-name") { |e|
          $per_txn_metrics[f.name] = e.text
        }

#        element.elements.each("event") { |e| f.events[e.attributes["alias"]] = e.text.upcase }
        element.elements.each("event") { |e|
          f.events[e.attributes["alias"]] = e.text;
#          method_system.concat("#{e.attributes["alias"]}=self[\"#{e.text}\"].per_system;")
#          method_socket.concat("#{e.attributes["alias"]}=self[\"#{e.text}\"].per_system;")
#          method_core.concat("#{e.attributes["alias"]}=self[\"#{e.text}\"].per_system;")
#          method_thread.concat("#{e.attributes["alias"]}=self[\"#{e.text}\"].per_system;")
        }

        element.elements.each("constant") { |e| f.constants[e.attributes["alias"]] = e.text }
        element.elements.each("formula") do |e|
          if e.attributes.empty?
            f.formula = e.text
          elsif processor_id = e.attributes["socket"]
            processor_id = processor_id.to_i
            f.per_processor_formulas[processor_id] = e.text
          end
        end
        if !f.per_processor_formulas.empty? && f.per_processor_formulas.compact.size < @system.sockets.count
          $stderr.puts " ERROR: only #{f.per_processor_formulas.compact.size} per-socket formulas are defined for metric #{f.name}. Formula must be defined for each socket."
        end
        formulas.push(f)

#        method_system.concat("end")
#        method_socket.concat("end")
#        method_core.concat("end")
#        method_thread.concat("end")

#        Hash.class_eval(method_system)
#        Hash.class_eval(method_socket)
#        Hash.class_eval(method_core)
#        Hash.class_eval(method_thread)

      end
      formulas
    rescue => err
      $stderr.puts " ERROR: parsing XML file #{file} failed."
      $stderr.puts err
      exit
    end
  end

  #
  # re-open the Hash class to add has_keys? function
  #
  class ::Hash
    def has_keys?(keys)
      (self.keys & keys).sort == keys.sort
      # keys.inject(true) {|result, key| result &&= self.has_key?(key)}
    end
  end

  # the core function for metric calculation
  def calculate_derived_metrics(events)
    # define a local variable without '@' prefix, so metrics definition file (XML) could
    # refer to system information like system.cpus.count or system.sockets[0][0].cpus.count
    system = @system
    # add two pseudo events, so they can be used in metric calculation
    # note QPI will be not necessary for SNB-EP, because there will be a UNC_Q_CLOCKTICKS event.

    if @options.sampling_interval.nil? && !@options.normalization_interval.nil?
      norm_interval = @options.normalization_interval * system.tsc_freq
      qpi_interval = @options.normalization_interval * system.qpi_freq
      events["TSC"] = Event.new("TSC " + " #{norm_interval.to_i}"*(system.cpus.count+1) )
      events["QPI"] = Event.new("QPI " + " #{norm_interval.to_i}" + " #{qpi_interval.to_i}"*system.sockets.count )
    else
      events["TSC"] = Event.new("TSC " + " #{system.tsc_freq.to_i}"*(system.cpus.count+1) )
      events["QPI"] = Event.new("QPI " + " #{system.tsc_freq.to_i}" + " #{system.qpi_freq.to_i}"*system.sockets.count )
    end

    metrics = Hash.new

    @formulas.each do |formula|
      if events.has_keys?(formula.events.values)  # if all the input events are available
        metric = Metric.new(formula.name)

        constants = ""
        formula.constants.each_pair {|al, ev| constants += "#{al} = #{ev}; "}
        
        # calculate per_system metric always
        variables = ""
        formula.events.each_pair {|al, ev| variables += "#{al} = events['#{ev}']; events['#{ev}'].indexed_by=:per_processor;"}
        metric.per_system = eval(constants+variables+formula.formula)
        metric.per_system += 0 if metric.per_system.is_a?(Event)
#        metric.per_system = events.send("metric_system_#{formula.formula_id}".to_sym)

        # calculate per_processor metric only if user requests to do it. 
        if @options.socket_view
          per_processor = Array.new(system.sockets.count)
          if formula.per_processor_formulas.nil? || formula.per_processor_formulas.empty?
            # if there is no ad hoc per_processor formulas, then we just use the universal formula
            per_processor.each_index do |processor_id|
              variables = ""
              formula.events.each_pair {|al, ev| variables += "#{al} = events['#{ev}'].per_processor(#{processor_id}); "}
              per_processor[processor_id] = eval(constants+variables+formula.formula)
            end
          else
            # if ad hoc per_processor formulas are provided, we should not use Event.per_processor.
            # instead, we should allow [i] to be used on Event object.
            formula.per_processor_formulas.each_with_index do |per_processor_formula, processor_id|
			        if system.sockets.ids.include?(processor_id)
                variables = ""
                formula.events.each_pair {|al, ev| variables += "#{al} = events['#{ev}']; events['#{ev}'].indexed_by=:per_processor; "}
                per_processor[processor_id] = eval(constants+variables+per_processor_formula)
			        end
            end
          end
          metric.per_processor = per_processor
        end

        if @options.core_view || @options.thread_view
          # calculate per_cpu and per_core metrics only if all input events are core events 
          # this is based on an assumption: if a metric is calculated from uncore event, it must be per_processor.
          all_core_events = formula.events.values.inject(true) {|all, ev| all &&= events[ev].is_per_cpu? }

          # calculate per_cpu metric
          if @options.thread_view && all_core_events
            per_cpu = Array.new(system.cpus.count)
            per_cpu.each_index do |cpu_id|
              variables = ""
              formula.events.each_pair {|al, ev| variables += "#{al} = events['#{ev}'].per_cpu(#{cpu_id});"}
              per_cpu[cpu_id] = eval(constants+variables+formula.formula)
            end
            metric.per_cpu = per_cpu
          end

          # calculate per_core metric
          if @options.core_view && all_core_events
            # note the returned per_core is a 2-D array.
            per_core = Array.new(system.sockets.count) { Array.new(system.sockets[0].count) }
            per_core.each_with_index do |cores, processor_id|
              cores.each_index do |core_id|
                variables = ""
                formula.events.each_pair {|al, ev| variables += "#{al} = events['#{ev}'].per_core(#{processor_id},#{core_id});"}
                per_core[processor_id][core_id] = eval(constants+variables+formula.formula)
              end
            end
            metric.per_core = per_core
          end
        end


        metrics[formula.name] = metric
      end # if all the input events are available.
    end # for each formula

    metrics
  end

end

#
# Event data
#
class Event
  
  # check if a line of data is a valid event data
  def self.is_valid_data?(data)
    columns = data.split(/\s+/)
    valid = true
    if columns.size >= 3  # valid data has at least 3 fields: event name, tsc, one or more per-cpu data
      columns[1..-1].each do |field|
        if !/^[\d,]+$/.match(field)  # only digits and comma are allowed for data fields
          valid = false
          break
        end
      end
    else
      valid = false
    end
    valid
  end

  # class variable that holds the reference to system topology object
  @@system = nil
  def self.system
    @@system
  end
  def self.system=(obj)
    @@system = obj
  end

  # class variable that holds the reference to system topology object
  @@options = nil
  def self.options
    @@options
  end
  def self.options=(obj)
    @@options = obj
  end

  #       name: event name
  #        tsc: tsc value (the first data field)
  #     fields: an array of values (the rest data fields)
  # indexed_by: a symbol that decides which value will be returned when accessing Event by [i]
  attr_accessor :name, :tsc, :fields, :indexed_by

  def initialize(data=nil)
    if data
      fields = data.split(/\s+/)
      @name = fields[0] #.upcase
      @tsc = fields[1].gsub(/,/, '').to_f
      if @@options.atom_tsc_wa
        # work-around for atom tsc issue. per Babita's request.
        @tsc = @tsc * 1000
      end
      if @@options.arm_tsc_multiplier
        @tsc = @tsc * @@options.arm_tsc_multiplier
      end
      @fields = fields[2..-1].collect { |x| x.gsub(/,/, '').to_f }
    end
    @indexed_by = :per_cpu
  end

  # a human-readable representation of the object
  def to_s
    "#{@name}\t#{@tsc}\t#{@fields.join('\t')}"
  end

  # without this method, Event.dup won't work properly.
  def initialize_copy(orig)
    @name = @name.dup
    #@tsc = @tsc.dup    # Float cannot be duplicated.
    @fields = @fields.dup
  end

  # sanity check
  def is_sane?
    result = true
    @fields.each do |f|
      if f > 128*@tsc
        result = false
        break
      end
    end
    result
  end

  # whether it is a core event
  def is_per_cpu?
    (@fields.size == @@system.cpus.count) && (@name.index('UNC_').nil? || @name.index('UNC_') != 0) 
  end

  # accumulate the same events from a different interval
  def accumulate!(other)
    if @name == other.name
      @tsc += other.tsc
      @fields.each_index {|i| @fields[i] += other.fields[i]}
    else
      raise "Cannot add up event #{@name} and #{other.name}"
    end
  end
  alias << accumulate!
	
  # normalize the events values into 1 second or requested interval
  def normalize!
	
    if !@@options.sampling_interval.nil? # check for --interval (-t) option
      time = @@options.sampling_interval # -t overrides --normalize
      @tsc = @@system.tsc_freq
    elsif @@options.normalization_interval.nil? # check for --normalize option
      # neither option selected, normalize to one second
      time = @tsc / @@system.tsc_freq
      @tsc = @@system.tsc_freq
    else # user specified a normalization interval
      norm_interval = @@options.normalization_interval * @@system.tsc_freq
      time = @tsc / norm_interval
      @tsc = norm_interval
    end
	
	if $flag_time != 0 
	$samplingTime=time
	$stdout.puts " Sampling Time: #{(time).to_f.round(4)}s"
	$flag_time=0
	end
	
    @fields.each_index { |i| @fields[i] /= time }
	
  end
	#$stdout.puts " Sampling Time: #{(@sampling_time).to_f.round(4)}"
  # the following 4 methods
  #     per_cpu
  #     per_core
  #     per_processor
  #     per_system
  # returns the event values from different perspective.
  # if parameter(s) is provided, they return a single value (Float),
  # otherwise they return an Array that can be accessed by [id] further.

  # return the per-cpu value, same as Event.per_cpu[id]
  # return nil if it is a uncore event
  def per_cpu(cpu_id=nil)
    if is_per_cpu?
      if cpu_id.nil?
        @fields
      else
        @fields[cpu_id]
      end
    else
      nil
    end
  end

  # return the per-core value, same as Event.per_core[p_id][c_id]
  # return nil if it is a uncore event
  def per_core(processor_id=nil, core_id=nil)
    if is_per_cpu?
      if processor_id.nil? || core_id.nil?
        result = Array.new(@@system.sockets.count) { Array.new(@@system.sockets[0].count) }
        result.each_with_index do |cores, p_id|
          cores.each_index do |c_id|
            cores[c_id] = 0.0
            @@system.sockets[p_id][c_id].cpus.each_pair {|cpu_id, cpu| cores[c_id] += @fields[cpu.cpu_index]}
          end
        end
        result
      else
        result = 0.0
        @@system.sockets[processor_id][core_id].cpus.each_pair {|cpu_id, cpu| result += @fields[cpu.cpu_index]}
        result
      end
    else
      nil
    end
  end

  # return the per-processor value, same as Event.per_processor[p_id]
  def per_processor(processor_id=nil)
    if processor_id.nil?
      if is_per_cpu?
        result = Array.new(@@system.sockets.count)
        result.each_index do |p_id|
          result[p_id] = 0.0
          @@system.sockets[p_id].cpus.each_pair { |cpu_id, cpu| result[p_id] += @fields[cpu.cpu_index]}
        end
        result
      else
        per_socket_array
      end
    else
      if is_per_cpu?
        result = 0.0
        @@system.sockets[processor_id].cpus.each_pair { |cpu_id, cpu| result += @fields[cpu.cpu_index]}
        result
      else
        per_socket_array[processor_id]
      end
    end
  end

  def per_socket_array
    num_sockets = @@system.sockets.size
    num_values_per_socket = @fields.size / num_sockets
    result = []
    (0..num_sockets-1).each { |i| result[i] = @fields[(i*num_values_per_socket)..((i+1)*num_values_per_socket-1)].sum}
    result
  end
  private :per_socket_array

  # return the system wide value
  def per_system
    @fields.sum
  end

  # allow Event to be accessed by [index]
  def [](index)
    if @@system.sockets.ids.include?(index)
      self.send(@indexed_by, index)
    else
      0.0
    end
  end

  def coerce(other)
    [other, self.per_system]
  end

  def +(other)
    self.per_system + other
  end
  def -(other)
    self.per_system - other
  end
  def *(other)
    self.per_system * other
  end
  def /(other)
    self.per_system / other
  end
  
  
end

#
# representing a metric.
# metric looks like Event, because they have similar interface.
# however, the underlying implementation are very different.
#
class Metric
  # class variable that holds the reference to system topology object
  @@system = nil
  def self.system
    @@system
  end
  def self.system=(obj)
    @@system = obj
  end

  #          name: metric's name
  #       per_cpu: an array of values
  #      per_core: a 2-D array
  # per_processor: an array of values
  #    per_system: just a number
  attr_accessor :name, :per_cpu, :per_core, :per_processor, :per_system

  def initialize(name)
    @name = name
    @per_cpu = nil
    @per_core = nil
    @per_processor = nil
    @per_system = nil
  end

  # without this method, Event.dup won't work properly.
  def initialize_copy(orig)
    @name = @name.dup
    @per_cpu = @per_cpu.dup
    @per_core = @per_core.dup
    @per_processor = @per_processor.dup
    @per_system = @per_system.dup
  end

  # whether this metric has per_cpu or per_core value
  def is_per_cpu?
    @per_core || (@per_cpu && (@per_cpu.size == @@system.cpus.count))
  end

  # return the per-processor value, same as per_processor[p_id]
  def per_processor(processor_id=nil)
    if processor_id == nil
      @per_processor
    else
      @per_processor[processor_id]
    end
  end

  # return the per-core value, same as per_core[p_id][c_id]
  def per_core(processor_id=nil, core_id=nil)
    if processor_id.nil? || core_id.nil?
      @per_core
    else
      @per_core[processor_id][core_id]
    end
  end

  # return the per_cpu value, same as per_cpu[cpu_id]
  def per_cpu(cpu_id=nil)
    if cpu_id.nil?
      @per_cpu
    else
      @per_cpu[cpu_id]
    end
  end
end

#
# a sample is a container of multiple events and metrics
#
class Sample
  # sample_num: the sample number.
  #     events: a Hash of event name => Event object
  #    metrics: a Hash of metric name => Metric object
  attr_accessor :sample_num, :timestamp, :events, :metrics

  def initialize
    @sample_num = nil
    @timestamp = nil
    @events = Hash.new
    @metrics = Hash.new
  end

  # add a event or metric
  def <<(obj)
    target = obj.is_a?(Event) ? @events : @metrics
    if target.has_key?(obj.name)
      target[obj.name].accumulate!(obj)
    else
      target[obj.name] = obj.dup
    end
  end

  def merge(sample)
    sample.events.each_value { |event|
      self << event
    }
    sample.metrics.each_value { |metric|
      self << metric
    }
  end

  # normalize all the events
  def normalize!
    @events.each_value {|event| event.normalize! }
  end

  # return the corresponding Event or Metric object, given a name
  def [](key)
    if @events.has_key?(key)
      @events[key]
    elsif @metrics.has_key?(key)
      @metrics[key]
    else
      nil
    end
  end
  
end

#
# representing the EMON data
#
class EmonData

  GROUP_BOUNDARY = "----------"
  LOOP_BOUNDARY  = "=========="
  @processedSamples=0
  attr_reader :names, :all_samples, :aggregated_sample, :thread_pool

  def initialize(options, system, formulas)
    @options = options
    @system = system
    @formulas = formulas
  end

  class RawSample
    def initialize(sample_num)
      @sample_num = sample_num
      @lines = Array.new
      @timestamp = nil
    end
    attr_accessor :sample_num, :lines, :timestamp
  end
  
  def process_chunk(samples)
    range, lines = samples

    # single sample
    intervals = Array.new
    loop = Sample.new         # aggregated sample from multiple samples in the same loop
    aggregated = Sample.new   # aggregated sample from all the samples from average_begin to average_end
    loop_existing_metrics = Array.new

    samples.each do |sample|
      interval = Sample.new     # a sample interval
      sample.lines.each do |line|
        if Event.is_valid_data?(line)
          event = Event.new(line)
          # TODO: drop the event if it does not pass the sanity checking.
          if event.is_sane?
            interval << event
            loop << event
            aggregated << event
          else
            $stderr.puts " WARNING: an insane event sample was detected and has been ignored. #{line}"
          end
        end        
      end
      interval.normalize!
      interval.metrics = @formulas.calculate_derived_metrics(interval.events)
      loop_existing_metrics += interval.metrics.keys
      interval.sample_num = sample.sample_num
      interval.timestamp = sample.timestamp
      intervals << interval
    end

    if samples.last.lines.last == LOOP_BOUNDARY
      # add loop metrics to the last sample of the loop
      # only those metrics that cannot in intervals are added.
      loop.normalize!
      loop.metrics = @formulas.calculate_derived_metrics(loop.events)
      loop_existing_metrics.uniq!
      loop.metrics.each_pair do |metric_name, metric_data|
        # merge the metrics from a loop into the last interval in the loop
        intervals.last.metrics[metric_name] = metric_data unless loop_existing_metrics.include?(metric_name)
      end
    end

    return [intervals, aggregated]
  end

  def reader_thread_body
    File.open(@file) do |f|
      sample_num = 1
      sample = RawSample.new(sample_num)
      samples = Array.new
      while (line=f.gets)
        line.chomp!
        sample.lines << line
        if line.match(/(\d\d)\/(\d\d)\/(\d\d\d\d) (\d\d):(\d\d):(\d\d)\.(\d+)/)
          month, day, year, hour, min, sec, msec = $1, $2, $3, $4, $5, $6, $7
          usec = msec + "000"  # the last part of timestamp in emon data is in milli-second. 
          sample.timestamp = Time.local(year, month, day, hour, min, sec, usec)
        end
        if line == GROUP_BOUNDARY || line == LOOP_BOUNDARY
          if (@begin_sample_timestamp || @end_sample_timestamp) && sample.timestamp.nil?
            if !$global_warning_no_timestamp_in_emon_data
              $stderr.puts "\n WARNING: timestamp was specified to drill down the data, but the EMON data was not collected with timestamp!" 
              $global_warning_no_timestamp_in_emon_data = true
            end
          end

          if @begin_sample_timestamp && sample.timestamp && sample.timestamp < @begin_sample_timestamp
            # if user specified a begin timestamp AND the current sample is earlier than the begin timestamp
            # then the next sample may be the first sample user is interested 
            @begin_sample_num = sample.sample_num + 1
          end

          if @end_sample_timestamp && sample.timestamp && sample.timestamp <= @end_sample_timestamp
            # if user specified an end timestamp AND the current sample is earlier than the begin timestamp
            # then the current sample may be the last sample user is interested
            @end_sample_num = sample.sample_num
          end

          if sample.sample_num >= @begin_sample_num && sample.sample_num <= @end_sample_num
            # if the sample is of user's interest
            samples << sample
            if line == LOOP_BOUNDARY || sample.sample_num==@average_end
              @input_data.enq(samples)
              samples = Array.new
            end
          end
            
          sample_num += 1 # need to increase the sample number by 1 even for skipped samples
          sample = RawSample.new(sample_num)
        end
      end # end of each line
      if !samples.empty?
        @input_data.enq(samples)
      end
    end # end of File.open
    num_threads = @options.parallel || 1
    num_threads.times { @input_data.enq(@input_data) }
  rescue => err
    puts err
    puts err.backtrace
  end

  def init_reader_thread
    @reader_thread = Thread.new do
      reader_thread_body
    end
  end

  def thread_body
    while (samples = @input_data.deq) != @input_data
      result = process_chunk(samples)
      @output_result.enq(result)
    end
    @output_result.enq(@output_result)
  rescue => err
    puts err
    puts err.backtrace
  end

  def init_thread_pool
    num_threads = @options.parallel || 1
    @thread_pool = Array.new(num_threads) {
      Thread.new { thread_body }
    }
  end

  def parse_emon_data
    @file = @options.input_file
    @begin_sample_num = (@options.average_begin &&
                         @options.average_begin.is_a?(Integer) &&
                         @options.average_begin >= 1 ) ? @options.average_begin : 1
    @end_sample_num = (@options.average_end &&
                       @options.average_end.is_a?(Integer) &&
                       @options.average_end >= 1) ? @options.average_end : Float::MAX
    @begin_sample_timestamp = (@options.average_begin &&
                               @options.average_begin.is_a?(Time)) ? @options.average_begin : nil
    @end_sample_timestamp = (@options.average_end &&
                             @options.average_end.is_a?(Time)) ? @options.average_end : nil

    if @file.nil?
      $stderr.puts " ERROR: emon data file must be specified!"
      exit
    end
    unless File.exist?(@file)
      $stderr.puts " ERROR: the emon data file #{@file} does not exist!"
      exit
    end

    @all_samples = Array.new
    @aggregated_sample = Sample.new
    
    @input_data = SizedQueue.new(1024)
    @output_result = SizedQueue.new(1024)

    init_reader_thread
    init_thread_pool
	
	
    num_samples = 0
    num_completed = 0
    num_threads = @options.parallel || 1
    $stdout.puts "\n Processing EMON data with #{num_threads} parallel threads..."
    if RUBY_PLATFORM != "java"
      # $stdout.puts " JRuby is required to take advantage of multi-threading."
    end
    t1=Time.now
    while num_completed < num_threads
      result = @output_result.deq
      if result == @output_result
        num_completed += 1
      else
        intervals, aggregated = result
        intervals.each { |sample| @all_samples[sample.sample_num-@begin_sample_num] = sample }
        num_samples += intervals.count
        $stdout.puts "     #{num_samples} samples processed" if num_samples % 10_000 == 0
        @aggregated_sample.merge(aggregated)
      end
    end
	#expose processedSamples to provide value to XML
	@processedSamples=num_samples
	$processed_samples=num_samples
    $stdout.puts "     #{num_samples} samples processed"
    $stdout.puts "     ============================"
    if @all_samples.size==0
      $stdout.puts "     ERROR: no sample detected. Please check the input data."
      exit
    end
    $stdout.puts "     sample #1 - ##{@begin_sample_num-1} are skipped." if @begin_sample_num > 1
    $stdout.puts "     sample ##{@all_samples.first.sample_num} - ##{@all_samples.last.sample_num} are extracted."

    @aggregated_sample.normalize!
    @aggregated_sample.metrics = @formulas.calculate_derived_metrics(@aggregated_sample.events)
    $stdout.puts "     #{@aggregated_sample.events.size} events parsed and #{@aggregated_sample.metrics.size} metrics derived."

    t2=Time.now
    $stdout.puts "     #{(t2-t1).ceil} seconds used."
  end

  def system_view
    SystemView.new(@options, @system, @all_samples, @aggregated_sample)
  end

  def socket_view
    SocketView.new(@options, @system, @all_samples, @aggregated_sample)
  end

  def core_view
    CoreView.new(@options, @system, @all_samples, @aggregated_sample)
  end

  def thread_view
    ThreadView.new(@options, @system, @all_samples, @aggregated_sample)
  end

attr_reader :processedSamples
end

#
# abstract calss View
#
class View
  attr_accessor :summary, :details, :per_txn_summary

  @@names = nil
  @@events_names = nil
  @@metrics_names = nil

  def initialize(options, system, all_samples, aggregated_sample)
    @options = options
    @system = system
    aggregated_sample.events = Hash[aggregated_sample.events.sort] #Sort the events in alphabetical order
    collect_names(aggregated_sample) if @@names.nil?
    generate(all_samples, aggregated_sample)
  end

  def collect_names(aggregated)
    @@events_names = aggregated.events.keys
    @@metrics_names = aggregated.metrics.keys
    # collect all the metric/event names
    all_names =  aggregated.metrics.keys + aggregated.events.keys
    @@names = Array.new
#    File.readlines(@options.chart_format).each do |line|
#      name = line.chomp.lstrip.rstrip
#      if all_names.include?(name)
#        @@names << name
#        all_names.delete(name)
#      else
#        $stderr.puts " WARNING: metric #{name} is not available!" unless name.empty?
#      end
#    end
    @@names += all_names
  end

  def output_csv
    view_name = self.class.to_s.gsub(/([a-z])([A-Z])/, '\1_\2').downcase

    summary_csv_file = @options.temp_dir.to_s + "__edp_#{view_name}_summary.csv"
    per_txn_summary_csv_file = @options.temp_dir.to_s + "__edp_#{view_name}_summary.per_txn.csv"
    details_csv_file = @options.temp_dir.to_s + "__edp_#{view_name}_details.csv"
    delimiter = ","

    File.open(details_csv_file, "w") do |f|
      @details.each do |row|
        f.print row.join(delimiter) + "\n"
      end
    end

    File.open(summary_csv_file, "w") do |f|
      @summary.each do |row|
        f.print row.join(delimiter) + "\n"
      end
    end

    if @options.tps && @per_txn_summary
      File.open(per_txn_summary_csv_file, "w") do |f|
        @per_txn_summary.each do |row|
          f.print row.join(delimiter) + "\n"
        end
      end
    end

    $stdout.puts "     results written to CSV files."
  end
  
end

#
# system view of the EMON data
#
class SystemView < View
  
  def generate(all, aggregated)
    $stdout.puts "\n Generating system view..."

    # header: a hash of metric/event name => corresponding headers array
    headers = Hash.new
    @@names.each do |key|
      headers[key] = headers.has_key?(key) || Array.new
      headers[key].push(key)
    end

    # generate the 2-D details table
    @details = Array.new
    all.each do |sample|
      row = Array.new
      @@names.each do |key|
        target = sample[key]
        if target
          # system level data
          row.push(target.per_system)
        else
          row.concat([nil]*headers[key].size)
        end
      end
      @details.push(row)
    end

    # transpose the details table, will be used to calculate min/max/stdev etc.
    transposed_details = @details.transpose

    # add header row and sample_num column to the @details
    all.each_with_index do |sample, index|
      @details[index].insert(0, sample.timestamp ? sample.timestamp.strftime("%m/%d/%Y %H:%M:%S.%L") : "")
      @details[index].insert(0, sample.sample_num)
    end
    header_row = ["#sample", "timestamp"]
    @@names.each {|name| header_row.concat(headers[name])}
    @details.insert(0,header_row)
    $stdout.puts "     details table generated."

    # generate the system summary table
    # generate header row for summary table
    @summary = Array.new
    header_row = ["(EDP #{EDP_VERSION}) name (sample ##{all[0].sample_num} - ##{all[-1].sample_num}) all events/metrics are normalized per second unless stated otherwise"]
    header_row.concat(["aggregated"])
    header_row.concat(["average"]) if @options.show_average
    header_row.concat(["min", "max", "95th percentile", "variation (stdev/avg)"])
    @summary.push(header_row)
    # generate data rows for summary table
    @@names.each_with_index do |key, index|
      row = Array.new
      row.push(key)
      target = aggregated[key]
      raise "should not happen" if target.nil?
      row.push(target.per_system)
      column = transposed_details[index].compact
      row.push(column.average) if @options.show_average
      row.push(column.min)
      row.push(column.max)
      row.push(column.max_95p)
      row.push(column.stdev/column.average)
      @summary.push(row)
    end
    $stdout.puts "     summary table generated."

    if @options.tps
      @per_txn_summary = Array.new
      header_row = ["(EDP #{EDP_VERSION}) name (sample ##{all[0].sample_num} - ##{all[-1].sample_num} TPS=#{@options.tps}) all events/metrics are normalized per txn unless stated otherwise"]
      header_row.concat(["aggregated"])  #only aggregated value can be applied to per-txn metrics or events
      @per_txn_summary.push(header_row)
      @@names.each_with_index do |key, index|
        row = Array.new
        if $per_txn_metrics.has_key?(key)
          row.push($per_txn_metrics[key])
          target = aggregated[key]
          raise "should not happen" if target.nil?
          inst_event = "INST_RETIRED.ANY"
		  if $is_AMD 
		    inst_event = "INST_RETIRED.ANY"
		  elsif $is_ARM
		    inst_event = "INSTRUCTIONS_OUT_OF_CORE_RENAMING"
		  end
          row.push(target.per_system*aggregated[inst_event].per_system/@options.tps)
        elsif @@events_names.include?(key)
          row.push(key)
          target = aggregated[key]
          raise "should not happen" if target.nil?
          row.push(target.per_system/@options.tps)
        elsif @@metrics_names.include?(key)
          row.push(key)
          target = aggregated[key]
          raise "should not happen" if target.nil?
          row.push(target.per_system)
        else
          $stderr.puts "!!!!! should not be here. #{key}"
          exit
        end
        @per_txn_summary.push(row)
      end
      $stdout.puts "     per-txn summary table generated."
    end
    
  end

end

#
# socket view of the EMON data
#
class SocketView < View

  def generate(all, aggregated)
    $stdout.puts " Generating socket view..."

    # header: a hash of metric/event name => corresponding headers array
    headers = Hash.new
    @@names.each do |key|
      headers[key] = headers.has_key?(key) || Array.new
      headers[key].concat((0...@system.sockets.count).to_a.collect {|processor_id| key+" (socket #{processor_id})" })
    end

    # generate the 2-D details table
    @details = Array.new
    all.each do |sample|
      row = Array.new
      @@names.each do |key|
        target = sample[key]
        if target
          # socket level data
          row.concat(target.per_processor)
        else
          row.concat([nil]*headers[key].size)
        end
      end
      @details.push(row)
    end

    # transpose the all_samples_table, will be used to calculate min/max/stdev etc.
    transposed_details = @details.transpose

    # add header row and sample_num column to the all_samples_table
    all.each_with_index do |sample, index|
      @details[index].insert(0, sample.timestamp ? sample.timestamp.strftime("%m/%d/%Y %H:%M:%S.%L") : "")
      @details[index].insert(0, sample.sample_num)
    end
    header_row = ["#sample", "timestamp"]
    @@names.each {|name| header_row.concat(headers[name])}
    @details.insert(0,header_row)
    $stdout.puts "     details table generated."

    # generate the summary table
    # generate header row for summary table
    @summary = Array.new
    header_row = ["(EDP #{EDP_VERSION}) name (sample ##{all[0].sample_num} - ##{all[-1].sample_num}) all events/metrics are normalized per second unless stated otherwise"]
    (0...@system.sockets.count).to_a.each {|p_id| header_row.push("socket #{p_id}")}
    @summary.push(header_row)
    # generate data rows for summary table
    @@names.each_with_index do |key, index|
      row = Array.new
      row.push(key)
      target = aggregated[key]
      raise "should not happen" if target.nil?
      target.per_processor.each {|v| row.push(v)}
      @summary.push(row)
    end
    $stdout.puts "     summary table generated."

    if @options.tps
      @per_txn_summary = Array.new
      header_row = ["(EDP #{EDP_VERSION}) name (sample ##{all[0].sample_num} - ##{all[-1].sample_num}) all events/metrics are normalized per second unless stated otherwise"]
      (0...@system.sockets.count).to_a.each {|p_id| header_row.push("socket #{p_id}")}
      @per_txn_summary.push(header_row)
      @@names.each_with_index do |key, index|
        row = Array.new
        if $per_txn_metrics.has_key?(key)
          row.push($per_txn_metrics[key])
          target = aggregated[key]
          raise "should not happen" if target.nil?
          target.per_processor.each_with_index { |v, i|
            inst_event = "INST_RETIRED.ANY"
            if $is_AMD 
		      inst_event = "INST_RETIRED.ANY"
		    elsif $is_ARM
		      inst_event = "INSTRUCTIONS_OUT_OF_CORE_RENAMING"
		    end
            normalized_value = v * aggregated[inst_event].per_processor[i]/@options.tps
            row.push(normalized_value)
          }
        elsif @@events_names.include?(key)
          row.push(key)
          target = aggregated[key]
          raise "should not happen" if target.nil?
          target.per_processor.each { |v|
            row.push(v/@options.tps)
          }
        elsif @@metrics_names.include?(key)
          row.push(key)
          target = aggregated[key]
          raise "should not happen" if target.nil?
          target.per_processor.each {|v| row.push(v)}
        else
          $stderr.puts "!!!!! should not be here. #{key}"
          exit
        end
        @per_txn_summary.push(row)
      end
      $stdout.puts "     per-txn summary table generated."
    end

  end

end

#
# core view of the EMON data
#
class CoreView < View

  def generate(all, aggregated)
    $stdout.puts " Generating core view..."

    # header: a hash of metric/event name => corresponding headers array
    headers = Hash.new
    @@names.each do |key|
      headers[key] = headers.has_key?(key) || Array.new
      target = aggregated[key]
      raise "should not happen" if target.nil?
      if target.is_per_cpu?
        @system.sockets.each_pair do |p_id, cores|
          cores.each_key do |c_id|
            headers[key].push(key+" (socket #{p_id} core #{c_id})")
          end
        end
      end
    end

    # generate the 2-D details table
    @details = Array.new
    all.each do |sample|
      row = Array.new
      @@names.each do |key|
        target = sample[key]
        if target
          # socket level data
          if target.is_per_cpu?
            row.concat(target.per_core.flatten)
          end
        else
          row.concat([nil]*headers[key].size)
        end
      end
      @details.push(row)
    end

    # transpose the all_samples_table, will be used to calculate min/max/stdev etc.
    transposed_details = @details.transpose

    # add header row and sample_num column to the all_samples_table
    all.each_with_index do |sample, index|
      @details[index].insert(0, sample.timestamp ? sample.timestamp.strftime("%m/%d/%Y %H:%M:%S.%L") : "")
      @details[index].insert(0, sample.sample_num)
    end
    header_row = ["#sample", "timestamp"]
    @@names.each {|name| header_row.concat(headers[name])}
    @details.insert(0,header_row)
    $stdout.puts "     details table generated."

    # generate the summary table
    # generate header row for summary table
    @summary = Array.new
    header_row = ["(EDP #{EDP_VERSION}) name (sample ##{all[0].sample_num} - ##{all[-1].sample_num}) all events/metrics are normalized per second unless stated otherwise"]
    @system.sockets.each_pair do |p_id, cores|
      cores.each_key do |c_id|
        header_row.push("socket #{p_id} core #{c_id}")
      end
    end
    @summary.push(header_row)
    # generate data rows for summary table
    @@names.each_with_index do |key, index|
      row = Array.new
      row.push(key)
      target = aggregated[key]
      raise "should not happen" if target.nil?
      if target.is_per_cpu?
        target.per_core.flatten.each {|v| row.push(v) }
      end
      @summary.push(row)
    end
    $stdout.puts "     summary table generated."

    if @options.tps
      @per_txn_summary = Array.new
      header_row = ["(EDP #{EDP_VERSION}) name (sample ##{all[0].sample_num} - ##{all[-1].sample_num}) all events/metrics are normalized per second unless stated otherwise"]
      @system.sockets.each_pair do |p_id, cores|
        cores.each_key do |c_id|
          header_row.push("socket #{p_id} core #{c_id}")
        end
      end
      @per_txn_summary.push(header_row)
      @@names.each_with_index do |key, index|
        row = Array.new
        if $per_txn_metrics.has_key?(key)
          row.push($per_txn_metrics[key])
          target = aggregated[key]
          raise "should not happen" if target.nil?
          if target.is_per_cpu?
            target.per_core.flatten.each_with_index {|v, i|
              inst_event = "INST_RETIRED.ANY"
              if $is_AMD 
		        inst_event = "INST_RETIRED.ANY"
		      elsif $is_ARM
		        inst_event = "INSTRUCTIONS_OUT_OF_CORE_RENAMING"
		      end
              normalized_value = v * aggregated[inst_event].per_core.flatten[i]/@options.tps
              row.push(normalized_value)
            }
          end
        elsif @@events_names.include?(key)
          row.push(key)
          target = aggregated[key]
          raise "should not happen" if target.nil?
          if target.is_per_cpu?
            target.per_core.flatten.each { |v|
              row.push(v/@options.tps)
            }
          end
        elsif @@metrics_names.include?(key)
          row.push(key)
          target = aggregated[key]
          raise "should not happen" if target.nil?
          if target.is_per_cpu?
            target.per_core.flatten.each {|v| row.push(v) }
          end
        else
          $stderr.puts "!!!!! should not be here. #{key}"
          exit
        end
        @per_txn_summary.push(row)
      end
      $stdout.puts "     per-txn summary table generated."
    end

  end

end

#
# thread view of the EMON data
#
class ThreadView < View

  def generate(all, aggregated)
    $stdout.puts " Generating thread view..."

    # header: a hash of metric/event name => corresponding headers array
    headers = Hash.new
    @@names.each do |key|
      headers[key] = headers.has_key?(key) || Array.new
      target = aggregated[key]
      raise "should not happen" if target.nil?
      if target.is_per_cpu?
        @system.cpus.each_key do |cpu_id|
          headers[key].push(key+" (cpu #{cpu_id})")
        end
      end
    end

    # generate the 2-D details table
    @details = Array.new
    all.each do |sample|
      row = Array.new
      @@names.each do |key|
        target = sample[key]
        if target
          # socket level data
          if target.is_per_cpu?
            row.concat(target.per_cpu.flatten)
          end
        else
          row.concat([nil]*headers[key].size)
        end
      end
      @details.push(row)
    end

    # transpose the all_samples_table, will be used to calculate min/max/stdev etc.
    transposed_details = @details.transpose

    # add header row and sample_num column to the all_samples_table
    all.each_with_index do |sample, index|
      @details[index].insert(0, sample.timestamp ? sample.timestamp.strftime("%m/%d/%Y %H:%M:%S.%L") : "")
      @details[index].insert(0, sample.sample_num)
    end
    header_row = ["#sample", "timestamp"]
    @@names.each {|name| header_row.concat(headers[name])}
    @details.insert(0,header_row)
    $stdout.puts "     details table generated."

    # generate the summary table
    # generate header row for summary table
    @summary = Array.new
    header_row = ["(EDP #{EDP_VERSION}) name (sample ##{all[0].sample_num} - ##{all[-1].sample_num}) all events/metrics are normalized per second unless stated otherwise"]
    @system.cpus.each_key do |cpu_id|
      cpu = @system.cpus[cpu_id]
      header_row.push("cpu #{cpu_id} (S#{cpu.processor_id}C#{cpu.core_id}T#{cpu.thread_id})")
    end
    @summary.push(header_row)
    # generate data rows for summary table
    @@names.each_with_index do |key, index|
      row = Array.new
      row.push(key)
      target = aggregated[key]
      raise "should not happen" if target.nil?
      if target.is_per_cpu?
        target.per_cpu.each {|v| row.push(v) }
      end
      @summary.push(row)
    end
    $stdout.puts "     summary table generated."

    if @options.tps
      @per_txn_summary = Array.new
      header_row = ["(EDP #{EDP_VERSION}) name (sample ##{all[0].sample_num} - ##{all[-1].sample_num}) all events/metrics are normalized per second unless stated otherwise"]
      @system.cpus.each_key do |cpu_id|
        cpu = @system.cpus[cpu_id]
        header_row.push("cpu #{cpu_id} (S#{cpu.processor_id}C#{cpu.core_id}T#{cpu.thread_id})")
      end
      @per_txn_summary.push(header_row)
      @@names.each_with_index do |key, index|
        row = Array.new
        if $per_txn_metrics.has_key?(key)
          row.push($per_txn_metrics[key])
          target = aggregated[key]
          raise "should not happen" if target.nil?
          if target.is_per_cpu?
            target.per_cpu.each_with_index {|v, i|
              inst_event = "INST_RETIRED.ANY"
              if $is_AMD 
                inst_event = "INST_RETIRED.ANY"
              elsif $is_ARM
                inst_event = "INSTRUCTIONS_OUT_OF_CORE_RENAMING"
              end
              normalized_value = v * aggregated[inst_event].per_cpu[i]/@options.tps
              row.push(normalized_value)
            }
          end
        elsif @@events_names.include?(key)
          row.push(key)
          target = aggregated[key]
          raise "should not happen" if target.nil?
          if target.is_per_cpu?
            target.per_cpu.each { |v|
              row.push(v/@options.tps)
            }
          end
        elsif @@metrics_names.include?(key)
          row.push(key)
          target = aggregated[key]
          raise "should not happen" if target.nil?
          if target.is_per_cpu?
            target.per_cpu.each {|v| row.push(v) }
          end
        else
          $stderr.puts "!!!!! should not be here. #{key}"
          exit
        end
        @per_txn_summary.push(row)
      end
      $stdout.puts "     per-txn summary table generated."
    end
    
  end

end

#
# Excel writer
#
class ExcelWriter

  def initialize(options)
    @options = options
  end

  def generate
    $stdout.puts "\n Generating Excel file..."

    if @options.output_file.nil?
      $stderr.puts(" ERROR: Please specify output file name using -o/--output.")
      $stderr.puts(" ERROR: Use -s 2 to directly go to excel creation when running again with -o.")
      return
    end

    require 'win32ole'

    @xl = WIN32OLE.new( "Excel.Application" )
    if !defined? WIN32OLE::XlContinuous
      WIN32OLE.const_load( @xl )
    end
    if @xl.nil?
      $stderr.puts "     failed to identify / find / start excel..."
      exit 1
    end
    @is_excel2010 = (@xl.version.to_i >= 14)
    @xl.Visible = false
    @xl.ScreenUpdating = false
    @xl.Interactive = false

    @workbook = @xl.workbooks.add
    (@workbook.sheets.count-1).times { @workbook.worksheets(1).delete }

    importConfig()
    importM()
    importV()
    importTextFile(@options.diskstat_file, "Disk Stat")
    importTextFile(@options.networkstat_file, "Network Stat")
    importTextFile(@options.dmidecode_file, "dimdecode")
    import_view('system')
    import_view('socket') if @options.socket_view
    import_view('core') if @options.core_view
    import_view('thread') if @options.thread_view

    sort_sheets

    excel_file = File.expand_path(@options.output_file).gsub('/', '\\' )
    File.delete( excel_file ) if File.exists?( excel_file )
    if @workbook
      @workbook.SaveAs( excel_file, WIN32OLE::XlOpenXMLWorkbook) #WIN32OLE::XlWorkbookDefault )
      @workbook.Close
      $stdout.puts("     workbook saved and closed: #{excel_file}")
    end
  rescue => err
    p err
    puts err.backtrace
  ensure
    if @xl
      @xl.Quit
      $stdout.puts("     Excel quit successfully.")
    end
  end

  def importTextFile(fileName, fileType)
	if !@fileName.nil? && File.exist?(fileName)	  
	 	$stdout.puts("     importing #{fileType} file")
		@importFile = fileName
		wb = @xl.Workbooks.Open(File.expand_path(@importFile).gsub('/','\\'))
		wb.sheets(1).name = fileType
		wb.sheets(1).Move(@workbook.sheets(1))
		@workbook.sheets(1).Tab.Color = 40*128  # green
		@workbook.sheets(1).Cells.Font.Name = "Calibri"
		@workbook.sheets(1).Cells.Font.Size = 10
		@workbook.sheets(1).Cells.NumberFormat = "#,##0"
		@workbook.sheets(1).Columns("A").NumberFormat = "#,##0"
	#else
        #$stderr.puts " WARNING: #{fileType} file does not exist."
    end
   end
  
  def importConfig()
  	if !@options.config_file.nil? &&  File.exist?(@options.config_file)
		$stdout.puts("     importing config")
		@configFile = @options.config_file
		wb = @xl.Workbooks.Open(File.expand_path(@configFile).gsub('/','\\'))
		wb.sheets(1).copy(@workbook.sheets(1))
		wb.close()
		@workbook.sheets(1).name = "Configuration"
		@workbook.sheets(1).Tab.Color = 40*128  # green
	else
        $stderr.puts " WARNING: configuration file does not exist."
	end
  end
  
  
  def importV()
    
    #@emonv = @options.emonv_file
   @emonv = $emon_v_file
	if !@emonv.nil? && File.exist?(@emonv)	  
		$stdout.puts("     importing emonV")
		wb = @xl.Workbooks.Open(File.expand_path(@emonv).gsub('/','\\'))
		wb.sheets(1).name = "emonV"
		wb.sheets(1).Move(@workbook.sheets(1))
		@workbook.sheets(1).Tab.Color = 40*128  # green
		@workbook.sheets(1).Cells.Font.Name = "Calibri"
		@workbook.sheets(1).Cells.Font.Size = 10
		@workbook.sheets(1).Cells.NumberFormat = "#,##0"
		@workbook.sheets(1).Columns("A").NumberFormat = "#,##0"
	else
        $stderr.puts " WARNING: emon-v file does not exist."
    end
  end
  
  def importM()
    
    #@emonM = @options.emonm_file
	@emonM = $emon_m_file
	if !@emonM.nil? && File.exist?(@emonM)	  
		$stdout.puts("     importing emonM")
		wb = @xl.Workbooks.Open(File.expand_path(@emonM).gsub('/','\\'))
		wb.sheets(1).name = "emonM"
		wb.sheets(1).Move(@workbook.sheets(1))
		@workbook.sheets(1).Tab.Color = 40*128  # green
		@workbook.sheets(1).Cells.Font.Name = "Calibri"
		@workbook.sheets(1).Cells.Font.Size = 10
		@workbook.sheets(1).Cells.NumberFormat = "#,##0"
		@workbook.sheets(1).Columns("A").NumberFormat = "#,##0"
		$stdout.puts("     imported emonM")
	else
        $stderr.puts " WARNING: emon-M file does not exist."
    end

  end

  def import_view(view)
    $stdout.puts("     importing #{view} view...")
    
    @summary_csv = @options.temp_dir.to_s + "__edp_#{view}_view_summary.csv"
    @per_txn_summary_csv_file = @options.temp_dir.to_s + "__edp_#{view}_view_summary.per_txn.csv"
    @details_csv = @options.temp_dir.to_s + "__edp_#{view}_view_details.csv"

    wb = @xl.Workbooks.Open(File.expand_path(@details_csv).gsub('/','\\'))
    wb.sheets(1).name = "details #{view} view"
    wb.sheets(1).Move(@workbook.sheets(1))
    @workbook.sheets(1).Tab.Color = 99  # red
    @workbook.sheets(1).Cells.Font.Name = "Calibri"
    @workbook.sheets(1).Cells.Font.Size = 8
    @workbook.sheets(1).Cells.NumberFormat = "#,##0.0000"
    @workbook.sheets(1).Columns("A").NumberFormat = "#,##0"
    if @options.timestamp_in_chart
	    @workbook.sheets(1).Columns("B").NumberFormat = "m/d/yyyy h:mm:ss.000;@"
    end
    @num_samples = File.readlines(@details_csv).size

    wb = @xl.Workbooks.Open(File.expand_path(@summary_csv).gsub('/','\\'))
    wb.sheets(1).name = "#{view} view"
    wb.sheets(1).Move(@workbook.sheets(1))
    @workbook.sheets(1).Tab.Color = 99*256  # green
    @workbook.sheets(1).Cells.Font.Name = "Courier New"
    @workbook.sheets(1).Cells.Font.Size = 10
    @workbook.sheets(1).Columns("A").ColumnWidth = 40
    @workbook.sheets(1).Cells.NumberFormat = "#,##0.0000"
    #@workbook.sheets(1).Activate
    #@xl.ActiveWindow.FreezePanes = true

    if @options.tps && File.exists?(@per_txn_summary_csv_file)
      wb = @xl.Workbooks.Open(File.expand_path(@per_txn_summary_csv_file).gsub('/','\\'))
      wb.sheets(1).name = "#{view} view (per-txn)"
      wb.sheets(1).Move(@workbook.sheets(1))
      @workbook.sheets(1).Tab.Color = 40*128  # green
      @workbook.sheets(1).Cells.Font.Name = "Calibri"
      @workbook.sheets(1).Cells.Font.Size = 11
      @workbook.sheets(1).Columns("A").ColumnWidth = 40
      @workbook.sheets(1).Cells.NumberFormat = "#,##0.0000"
    end

    if @options.chart_format && File.exists?(@options.chart_format)
      plot_charts(view)
    end
  end

  def plot_charts(view)
    chart_sheet = @workbook.sheets.Add
    chart_sheet.Tab.Color = 99*256*256  # blue
    chart_sheet.name = "chart #{view} view"
    chart_sheet.Cells.Font.Name = "Calibri"
    chart_sheet.Cells.Font.Size = 8

    # open charts file and render every combination listed here...
    #
    chart_width  = 306
    chart_height = 258
    chart_border = 10
    chart_x      = chart_border
    chart_y      = chart_border
    plotted      = false

    num_charts = 0
    $stdout.print("        plotting charts for #{view} view: ")
    time_begin = Time.now
    File.readlines(@options.chart_format).each do |metric|
      if /^\n/.match( metric )
        # empty line means a new row of charts
        chart_x = chart_border
        if plotted
          chart_y += chart_height + chart_border
          plotted = false
        end
        next
      end

      data = find_batch(view, metric)
      xdata = @options.timestamp_in_chart ? find(view, "timestamp") : find(view, "#sample")

      if data and !data.empty?
        chart_object = chart_sheet.ChartObjects.Add( chart_x, chart_y, chart_width, chart_height )
        chart = chart_object.Chart
        index = 1
        data.each_pair do |serie_name, serie_data_range|
          chart.SeriesCollection.NewSeries
          chart.SeriesCollection(index).Name = serie_name
          chart.SeriesCollection(index).XValues = xdata.values[0]
          chart.SeriesCollection(index).Values = serie_data_range
          index += 1
        end
        chart.HasTitle = true
        chart.ChartTitle.Font.Size = 11
        chart.ChartTitle.Text = metric
        chart.Parent.RoundedCorners = true
        chart.ChartArea.Shadow = true
        chart.ChartArea.Format.Shadow.Transparency = 0.75
        chart.ChartType = WIN32OLE::XlXYScatterLines
        chart.SetElement( 104 ) # 104 = msoElementLegendBottom
        #chart.SetElement( 100 ) # 100 = msoElementLegendNone
        if !@options.timestamp_in_chart # do this only when the x-axis is number of sample
          if @options.average_begin.is_a?(Integer)
            chart.Axes(1).MinimumScale = @options.average_begin
          end
        else
          # xlTickLabelOrientationUpward	-4171	Text runs up.
          # http://msdn.microsoft.com/en-us/library/office/bb216366%28v=office.12%29.aspx
          chart.Axes(1).TickLabels.Orientation = -4171
          #chart.Axes(1).TickLabels.NumberFormat = "hh:mm:ss"
		      chart.Axes(1).TickLabels.NumberFormat = "h:mm:ss.000;@"
          chart.Axes(1).TickLabels.Font.Size = 7
        end

        chart_x += chart_width + chart_border
        num_charts +=1
        plotted = true
        $stdout.print("+")
      end
    end
    time_end = Time.now
    $stdout.puts("\n        #{num_charts} charts plotted in #{time_end-time_begin} seconds. ")
  end

  def sort_sheets
    pos = 1

    sheets = ["Configuration", "system view", "socket view", "core view", "thread view",
              "system view (per-txn)", "socket view (per-txn)", "core view (per-txn)", "thread view (per-txn)",
              "chart system view", "chart socket view", "chart core view", "chart thread view",
              "details system view", "details socket view", "details core view", "details thread view"]
    available_sheets = []
    (1..@workbook.sheets.count).each { |i| available_sheets.push(@workbook.sheets[i].name) }
    sheets = sheets - (sheets - available_sheets)
    sheets.each do |name|
      @workbook.sheets(name).Move(@workbook.worksheets(pos))
      pos += 1
    end

    @workbook.sheets(@workbook.sheets.count).delete

    @workbook.sheets(1).select
  end

  def find_batch(view, metrics)
    results = {}
    metrics.split(",").each do |metric|
      metric = metric.chomp.lstrip.rstrip
      results.merge!(find(view, metric))
    end
    return results
  end

  def find(view, metric)
    # returs a range string of data that matches this key or nil depending
    # on the match...
    #
    first   = nil
    result  = {}

    keys = @workbook.Worksheets("details #{view} view").Range( "A1" ).EntireRow
    # find first match...
    #

    current = keys.Find( metric,
                        nil,
                        WIN32OLE::XlValues,
                        WIN32OLE::XlPart,
                        WIN32OLE::XlByColumns,
                        WIN32OLE::XlNext,
                        false,
                        false,
                        false )

    while !current.nil?
      if first.nil?
        first = current
      elsif current.Address == first.Address
        break
      end
      serie_name = current.value.gsub(metric, '').lstrip.rstrip
      # when the row value is a substring of the current.value, e.g., INST_RETIRED.ANY vs. BR_INST_RETIRED.ANY
      if serie_name.empty? || /^\(.*\)$/.match(serie_name)
        if /(\$[A-Z]+)\$([0-9]+)$/.match( current.address )
          last_row = @num_samples
          if !@is_excel2010 && @num_samples>32_000
            last_row = 32_001
          end
          serie_data_range = "='details #{view} view'!#{$1}\$2:#{$1}\$#{last_row}"
          serie_name = current.value.gsub(metric, '').lstrip.rstrip.gsub('(','').gsub(')','')
          serie_name = 'system' if serie_name.empty?
          result["#{metric} (#{serie_name})"] = serie_data_range
        else
          $stderr.puts " failed to excel address format for #{metric}...\n\n"
        end
      end
      current = keys.FindNext( current )
    end
    
    return result
  end

end

def main
  puts "\nEDP version #{EDP_VERSION}; Ruby platform is #{RUBY_ENGINE} #{RUBY_VERSION}"
  
  options = Options.new
  
  system = Topology.new(options)

  formulas = Formulas.new(options, system)

  Event.system = system
  Event.options = options
  Metric.system = system
  			
  $flag_time=1
  $samplingTime=0
  $processed_samples=0
  
  
  if options.step.nil? || options.step == 1
    emon_data = EmonData.new(options, system, formulas)
	
    emon_data.parse_emon_data
	
    system.sampling_time=$samplingTime
	system.numSamples=$processed_samples
	
	
    system_view = emon_data.system_view
    system_view.output_csv

    if options.socket_view
      socket_view = emon_data.socket_view
      socket_view.output_csv
    end

    if options.core_view
      core_view = emon_data.core_view
      core_view.output_csv
    end

    if options.thread_view
      thread_view = emon_data.thread_view
      thread_view.output_csv
    end

    emon_data = nil
    system_view = nil
    socket_view = nil
    core_view = nil
    thread_vew = nil
    ObjectSpace.garbage_collect
	
  end
 
  if options.step.nil? || options.step == 2
    if !(/cygwin|mswin|mingw|bccwin|wince|emx/ =~ RbConfig::CONFIG['host_os']).nil?
      # If on windows, use ExcelWriter class which uses windows specific win32ole
      ExcelWriter.new(options).generate
    else
      if options.output_file.nil?
         $stderr.puts(" ERROR: Please specify output file name using -o/--output.")
         $stderr.puts(" ERROR: Use -s 2 to directly go to excel creation when running again with -o.")
         return
      end
      str_options = "--output \"#{options.output_file}\" "
      str_options += "--temp-dir \"#{options.temp_dir}\" " if options.temp_dir
      str_options += "--config \"#{options.config_file}\" " if options.config_file
      str_options += "--format \"#{options.chart_format}\" " if options.chart_format
      str_options += "--emonm \"#{options.emonm_file}\" " if options.emonm_file
      str_options += "--emonv \"#{options.emonv_file}\" " if options.emonv_file
      str_options += "--network-stat \"#{options.networkstat_ile}\" " if options.networkstat_file
      str_options += "--dmidecode \"#{options.dmidecode_file}\" " if options.dmidecode_file
      str_options += "--disk-stat \"#{options.diskstat_file}\" " if options.diskstat_file
      str_options += "--tps \"#{options.tps}\" " if options.tps
      str_options += "--timestamp-in-chart " if options.timestamp_in_chart
      str_options += "--socket-view " if options.socket_view
      str_options += "--thread-view " if options.thread_view
      str_options += "--core-view " if options.core_view
      str_options.gsub!("\\", "")
      excel_writer = File.expand_path(File.dirname(__FILE__)) + "/excel_writer.py"
      if File.exists?(excel_writer)
        system("python3 #{excel_writer} #{str_options}")
      else
        $stderr.puts "Please make sure excel_writer.py is located at #{excel_writer}"
      end
    end
  end
  system.sampling_time=$samplingTime
  system.numSamples=$processed_samples
  
 
end

main
