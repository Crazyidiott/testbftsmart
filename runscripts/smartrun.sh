# Copyright (c) 2007-2013 Alysson Bessani, Eduardo Alchieri, Paulo Sousa, and the authors indicated in the @author tags
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# JVM Memory Settings
# -Xmx4g: Maximum heap size 4GB
# -Xms2g: Initial heap size 2GB
JAVA_OPTS="-Xmx4g -Xms2g"

# GC Logging (optional, enable by setting ENABLE_GC_LOG=true)
# GC logs will be written to gc_<processid>.log in the working directory
ENABLE_GC_LOG="${ENABLE_GC_LOG:-false}"

if [ "$ENABLE_GC_LOG" = "true" ]; then
    # Extract server ID from arguments (for ThroughputLatencyServer, it's the 2nd argument after class name)
    # Example: smartrun.sh bftsmart.demo.microbenchmarks.ThroughputLatencyServer 0 1000 ...
    #                      $1                                                    $2
    SERVER_ID="${2:-$$}"  # Use PID as fallback if no server ID
    
    # Java 8/11 compatible GC logging
    GC_OPTS="-Xlog:gc*:file=gc_${SERVER_ID}.log:time,uptime,level,tags"
    
    JAVA_OPTS="$JAVA_OPTS $GC_OPTS"
    echo "GC logging enabled: gc_${SERVER_ID}.log"
fi

java $JAVA_OPTS -Djava.security.properties="./config/java.security" -Dlogback.configurationFile="./config/logback.xml" -cp "lib/*" $@