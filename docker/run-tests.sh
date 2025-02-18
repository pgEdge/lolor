#!/bin/bash

IFS=',' read -r -a peer_names <<< "$PEER_NAMES"

for PEER_HOSTNAME in "${peer_names[@]}";
do
  while ! pg_isready -h $PEER_HOSTNAME; do
    echo "Waiting for $PEER_HOSTNAME..."
    sleep 1
  done
done


#==================== Javascript tests ====================
cd /home/pgedge/lolor/tests/javascript
cp ../../docker/test-configs/config.json config.json
npm install --save-dev jest
npm install --save pg
npm install --save pg-large-object
npm install --save express
npm test &> /home/pgedge/lolor/tests/out.txt

sleep 10

#==================== Junit tests ====================
cd /home/pgedge/lolor/tests/junit/multinode
cp ../../../docker/test-configs/test.properties.java test.properties
mvn test &>> /home/pgedge/lolor/tests/out.txt
mvn -Dtest=TestLOMethods test &>> /home/pgedge/lolor/tests/out.txt
mvn -Dtest=TestLOMethods#t1 test &>> /home/pgedge/lolor/tests/out.txt

sleep 10

cd /home/pgedge/lolor/tests/junit/singlenode
cp ../../../docker/test-configs/test.properties.java-single test.properties
mvn test &>> /home/pgedge/lolor/tests/out.txt
mvn -Dtest=TestLargeObjectAPI test &>> /home/pgedge/lolor/tests/out.txt
mvn -Dtest=TestLargeObjectAPI#testInsert test &>> /home/pgedge/lolor/tests/out.txt

sleep 10

#==================== Python tests ==================== 
cd /home/pgedge/lolor/tests/python
cp ../../docker/test-configs/test.properties.py test.properties
python3 lolor_tests.py -v &>> /home/pgedge/lolor/tests/out.txt

sleep 10

#==================== Golang tests ====================   

cd /home/pgedge/lolor/tests/go
go get github.com/jackc/pgx/v5
go get github.com/magiconair/properties
cp ../../docker/test-configs/test.properties.go test.properties
go test -v &>> /home/pgedge/lolor/tests/out.txt
