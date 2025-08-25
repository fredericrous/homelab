to finish the config you will need to:

- get the token from plex.daddyshome.fr/claim 
- set PLEX_CLAIM inn deployment.yaml (or better yet, vault) and redeploy

once connected to plex,

- insure Remote Access says "Fully accessible outside your network"
- manually set public port to 443
