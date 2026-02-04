CREATE DATABASE IF NOT EXISTS orchestrator;
CREATE USER 'orc_server_user'@'%' IDENTIFIED BY 'orc_server_password';
GRANT ALL PRIVILEGES ON orchestrator.* TO 'orc_server_user'@'%';

CREATE USER 'orc_client_user'@'%' IDENTIFIED BY 'orc_client_password';
GRANT SELECT, PROCESS, RELOAD, REPLICATION CLIENT, REPLICATION SLAVE, SHOW DATABASES ON *.* TO 'orc_client_user'@'%';

FLUSH PRIVILEGES;
