import os
import sys
import pathlib
import logging as std_logging

# Set up logging
# Modify the `level` value to change the logging level
std_logging.basicConfig(stream=sys.stdout, level=std_logging.DEBUG)

class logging:
    @staticmethod
    def debug(msg):
        print(msg)
    @staticmethod
    def info(msg):
        print(msg)
    @staticmethod
    def error(msg):
        print(msg)

# We have limitations on how Pulumi can be called.
# Because the CWD must be where Pulumi.yaml resides,
# we cannot make the Pulumi CLI work from the root of the Everything repo.
# Therefore, we will check to see if the CWD is where we expect it to be
# by listing all of the possible locations of the jupiter directory
# in all checkouts of the Everything repo.
def get_cwd():
    known_jupiter_paths = [
        # MUT: Update this list with all possible paths to jupiter.
        '/Users/yuto/src/everything/jupiter',
    ]
    if os.getcwd() not in known_jupiter_paths:
        raise Exception(f"Pulumi was called when CWD was an unexpected value. Update the list in share.py as appropriate.")
    return pathlib.Path(os.getcwd())

# We assume that CWD is in everything/jupiter
generated_json_path = get_cwd().joinpath('..', 'exports', 'jupiter', 'generated.json')