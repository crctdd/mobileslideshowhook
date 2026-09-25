# 0.0.1 packaging fix

Removed the optional `layout/DEBIAN/postinst` maintainer script.
This avoids GitHub/ZIP executable-permission loss causing dpkg to reject mode 0644.
The tweak version remains `0.0.1`.
After installation, force-close Photos and reopen it.
