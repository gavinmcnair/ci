FROM debian:bookworm-slim
RUN uname -m > /arch.txt
CMD cat /arch.txt && echo "CI runner works"
