#!/bin/bash
RESUME_OFFSET=$(btrfs inspect-internal map-swapfile -r /swap/swapfile)
