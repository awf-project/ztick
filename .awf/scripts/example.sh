#!/usr/bin/env bash
# Example script created by awf init
# This script demonstrates the script_file feature (B009).
# Reference it in a workflow step:
#
#   states:
#     run_script:
#       type: step
#       script_file: "{{.awf.scripts_dir}}/example.sh"
#       on_success: done

echo "Hello from AWF script!"
