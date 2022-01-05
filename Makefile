.PHONY: filebeat rsyslog logstash prepare fluentbit
.NOTPARALLEL:

test ?= 100
compression ?= none
acks ?= 0

KAF := ~/go/bin/kaf
DESCRIBE := $(KAF) --brokers "10.2.20.101:9092,10.2.20.102:9092,10.2.20.103:9092" topic describe logs

# Example
# make logstash test=100 compression=lz4 acks=1


mk_logs:
	@for i in 10 1000 10000 100000 1000000 10000000 100000000 1000000000; do     \
		docker run -i --rm                                                   \
		mingrammer/flog -n $${i} > ./input/$${i}.log;                        \
	done;                                                                        \

pre:
	@$(KAF) --brokers "10.2.20.101:9092,10.2.20.102:9092,10.2.20.103:9092"       \
		topic delete logs;                                                   \
	docker run --rm -i                                                           \
		-v `pwd`/topicctl/:/topicctl/:ro                                     \
		segment/topicctl                                                     \
		apply /topicctl/topics/logs.yaml                                     \
		--cluster-config /topicctl/cluster.yaml                              \
		--skip-confirm;                                                      \
	echo "start=`date +%s`" > tmp/results

post: 
	@echo "end=`date +%s`" >> tmp/results;                                                                       \
	$(DESCRIBE) | awk -F: '/^Summed HighWatermark/ {gsub(/ /,""); print "records_received="$$2}' >> tmp/results; \
	echo "records_sent=`cat input/$(test).log | wc -l`" >> tmp/results;                                          \
	. `pwd`/tmp/results;                                                                                         \
        duration=`echo "$${end} - $${start}" | bc`;                                                                  \
	echo "";                                                                                                     \
	echo "================================================================================";                     \
        echo "Time taken = $${duration} seconds";                                                                    \
	echo "Records lost = `echo "$${records_sent} - $${records_received}" | bc`";                                 \
	echo "================================================================================"

debug:
	@echo "";                                                                                                     \
	echo "================================================================================";                     \
	echo "First records:";                                                                                       \
	$(KAF) --brokers "10.2.20.101:9092,10.2.20.102:9092,10.2.20.103:9092"                                        \
		consume logs --offset oldest --limit-messages 1;                                                     \
	echo "================================================================================";                     \
	echo "Last records:";                                                                                        \
	$(KAF) --brokers "10.2.20.101:9092,10.2.20.102:9092,10.2.20.103:9092"                                        \
		consume logs --tail 1;                                                                               \
	echo "================================================================================"

fluentbit: pre run_fluentbit post

logstash: pre run_logstash post

filebeat: pre run_filebeat post

rsyslog: pre run_filebeat post

run_logstash:
	@start=`date +%s`;                                                           \
	cat input/$(test).log                                                        \
		| docker run --rm -i                                                 \
		-e "compression=$(compression)"                                      \
		-e "acks=$(acks)"                                                    \
		-e "LOG_LEVEL=error"                                                 \
		-e "XPACK_MONITORING_ENABLED=false"                                  \
		-v `pwd`/logstash/:/usr/share/logstash/pipeline/:ro                  \
		logstash:7.16.2

run_rsyslog:
	@cat rsyslog/*                                                               \
	       | sed "s/__COMPRESSION__/$(compression)/g"                            \
	       | sed "s/__ACKS__/$(acks)/g"                                          \
	       > tmp/rsyslog.conf;                                                   \
	docker run --rm -i                                                           \
		-v `pwd`/tmp/rsyslog.conf:/etc/rsyslog.d/rsyslog.conf                \
		-v `pwd`/input/$(test).log:/input/input.log                          \
		levonet/rsyslog

run_filebeat:
	@start=`date +%s`;                                                           \
	cat input/$(test).log                                                        \
                | docker run --rm -i                                                 \
		 -v `pwd`/filebeat/filebeat.yml:/usr/share/filebeat/filebeat.yml     \
		docker.elastic.co/beats/filebeat:6.8.22                              \
		filebeat -e -strict.perms=false --once

run_fluentbit:
	@start=`date +%s`;                                                           \
        cat fluentbit/*                                                              \
		| sed "s/__COMPRESSION__/$(compression)/g"                           \
		| sed "s/__ACKS__/$(acks)/g"                                         \
		> tmp/fluentbit.conf;                                                \
	docker run --rm -i -v `pwd`/tmp/fluentbit.conf:/config/fluentbit.conf:ro -v `pwd`/input/$(test).log:/input/input.log:ro fluent/fluent-bit:latest /fluent-bit/bin/fluent-bit -c /config/fluentbit.conf
