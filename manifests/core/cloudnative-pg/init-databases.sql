-- Create Harbor user
CREATE USER harbor WITH PASSWORD 'HarborDB123';

-- Create Harbor databases
CREATE DATABASE registry OWNER harbor;
CREATE DATABASE core OWNER harbor;
CREATE DATABASE notary_signer OWNER harbor;
CREATE DATABASE notary_server OWNER harbor;

-- Grant permissions on Harbor databases
GRANT ALL PRIVILEGES ON DATABASE registry TO harbor;
GRANT ALL PRIVILEGES ON DATABASE core TO harbor;
GRANT ALL PRIVILEGES ON DATABASE notary_signer TO harbor;
GRANT ALL PRIVILEGES ON DATABASE notary_server TO harbor;

-- Create LLDAP user and database
CREATE USER lldap WITH PASSWORD 'lldap-db-password';
CREATE DATABASE lldap OWNER lldap;
GRANT ALL PRIVILEGES ON DATABASE lldap TO lldap;

-- Grant schema permissions will be done after databases are created
\c registry
GRANT ALL ON SCHEMA public TO harbor;

\c core
GRANT ALL ON SCHEMA public TO harbor;

\c notary_signer
GRANT ALL ON SCHEMA public TO harbor;

\c notary_server
GRANT ALL ON SCHEMA public TO harbor;

\c lldap
GRANT ALL ON SCHEMA public TO lldap;