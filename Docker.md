# Docker Setup

Run `docker build -t <tag> .` in the cloned repo.

Then run `docker run -d -p 27015:27015/tcp -p 27015:27015/udp -p 27131:27131 -p 27131:27131/udp -p 51422:51422 -p 7777:7777 -p 7777:7777/udp <tag>` to start an container.
