##ruby interpreter, change it according to the path where ruby is installed in your system
RUBY=ruby

##input file names, you may need to change them
EMON_DATA=emon.dat
EMON_V=emon-v.dat
EMON_M=emon-M.dat

##Workload related H/W and S/W configuration file; imported as-is into EDP spreadshe
CONFIG_FILE=config.xlsx

##Output of dmidecode; imported as-is into EDP spreadsheet
DMIDECODE_FILE=dmidecode.txt

##output of sar or other tool with network traffic
NETWORKSTAT_FILE=network.txt

##output of iostat or other tool with disk traffic
DISKSTAT_FILE=diskstat.txt

##output file name, you may want to change it

OUTPUT=summary.xlsx

##the metrics definition file; need to change this based on the architecture
METRICS=metric.xml

##Excel chart format file, Need to change it based on the architecture
CHART_FORMAT=chart_format.txt

##the average value will be calculated from the %BEGIN% sample to %END% sample.
##setting %END% to a negative value means the last availabe sample.
BEGIN=1200
END=1000000

VIEW="--socket-view --core-view --thread-view"

ruby edp.rb -i $EMON_DATA -j $EMON_V -k $EMON_M -g $CONFIG_FILE -d $DMIDECODE_FILE -D $DISKSTAT_FILE -n $NETWORKSTAT_FILE -f $CHART_FORMAT -o $OUTPUT -m $METRICS -b $BEGIN -e $END $VIEW $TPS $TIMESTAMP_IN_CHART

