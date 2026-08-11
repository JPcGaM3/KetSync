"""Read-only companion to ct-migrate.sh.

The bash engine is the only thing that writes. Everything in this package
reads what it left behind: inventory-migrate.tsv, ctmig.conf, done/*.done and the
state/ directory. Nothing here is required for a migration to work, which is
deliberate -- a Proxmox node has no jq and no guaranteed python3, so the
engine can never depend on this.
"""

__version__ = "0.3.0"
SCHEMA_VERSION = 1
