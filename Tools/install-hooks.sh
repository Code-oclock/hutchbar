#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
git config core.hooksPath .githooks
echo 'Installed repository hooks (.githooks). No system configuration changed.'
