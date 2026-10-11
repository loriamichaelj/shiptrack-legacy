#!/usr/bin/env python3
"""Upload this host's proof-of-delivery files to S3 and rewrite their rows (release v1.1.0).

A thin entry point for cron and for the ShipTrack-PodSync SSM document. The work, and its tests,
are in shiptrack.jobs.pod_to_s3. Run it with the release's virtualenv:

    /opt/shiptrack/current/venv/bin/python /opt/shiptrack/current/scripts/migrate_pod_to_s3.py \
        --bucket <pod bucket> [--dry-run]
"""

import sys

from shiptrack.jobs.pod_to_s3 import main

if __name__ == "__main__":
    sys.exit(main())
