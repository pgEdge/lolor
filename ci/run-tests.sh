#!/bin/bash

IFS=',' read -r -a peer_names <<< "$PEER_NAMES"

for PEER_HOSTNAME in "${peer_names[@]}";
do
  while ! pg_isready -h $PEER_HOSTNAME; do
    echo "Waiting for $PEER_HOSTNAME..."
    sleep 1
  done
done

#==================== Golang tests ====================   

cd /home/pgedge/lolor/tests/go
go get github.com/jackc/pgx/v5
go get github.com/magiconair/properties
cp ../../ci/test-configs/test.properties.go test.properties

go test -v

#==================== Javascript tests ====================
cd /home/pgedge/lolor/tests/javascript
cp ../../ci/test-configs/config.json config.json
npm test

#==================== Junit tests ====================
#cd /home/pgedge/lolor/tests/junit/singlenode
#cp ../../../ci/test-configs/test.properties.java-single test.properties
#mvn test
#
cd /home/pgedge/lolor/tests/junit/multinode
cp ../../../ci/test-configs/test.properties.java test.properties
mvn test

#==================== Python tests ==================== 
cd /home/pgedge/lolor/tests/python
cp ../../ci/test-configs/test.properties.py test.properties
python3 lolor_tests.py -v
