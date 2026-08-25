"""pyinfra inventory — this Mac, over the @local connector.

No SSH, no remote host. Everything runs as the invoking user, in this directory.
"""

hosts = ["@local"]
