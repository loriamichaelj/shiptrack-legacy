# Included by every server and location that sets its own headers: an add_header inside a
# location cancels inheritance of all server-level add_header directives, so this line must be
# repeated wherever add_header appears or responses silently lose the stack header.
add_header X-ShipTrack-Stack legacy always;
