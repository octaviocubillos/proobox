arch=$(uname -m)
hello=$(cat <<EOF
Hello from Proobox!
 "This message shows that your installation appears to be working correctly."

To generate this message, Proobox took the following steps:
 1. The Proobox client contacted the Proobox script.
 2. The Proobox daemon pulled the "hello-world" image from the Proobox Hub.
    (${arch}) 
 3. The Proobox daemon created a new container from that image which runs the
    executable that produces the output you are currently reading.
 4. The Proobox daemon streamed that output to the Proobox client, which sent it
    to your terminal.

To try something more ambitious, you can run an Ubuntu container with:
 $ proobox run -it ubuntu bash

EOF
)

echo "$hello"