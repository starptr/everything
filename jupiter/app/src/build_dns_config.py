"""A DigitalOcean Python Pulumi program"""

import json
import logging as std_logging
import os
import pathlib
import re
import share
from share import logging

#pulumi_config = pulumi.Config()
#do_token = pulumi_config.require_object('token')

# TODO: Check that this file was called when CWD is at `src/`

template_pattern = re.compile(r'＜\s*(\S+)\s*＞')

class TemplateVarKeyError(Exception):
    def __init__(self, template_var):
        self.template_var = template_var
        super().__init__(self, str(self))

    def __str__(self):
        return f"Key not found in data: {self.template_var}"

def inject_data_into_octodns_templates(data):
    logging.info("Building yaml files from templates (populated with generated data from pulumi) for octodns...")
    def get_files() -> pathlib.Path:
        for (dirpath, dirnames, filenames) in os.walk(share.octodns_config_template_path):
            for filename in filenames:
                full_filepath = os.path.join(dirpath, filename)
                path = pathlib.Path(full_filepath)
                logging.debug(f"Found file: {path}")
                yield path
            break # Only read the top level directory, i.e. don't recurse
    def build_octodns_config_from_yaml_template(template_path, data):
        build_dir_path = pathlib.Path(share.octodns_config_build_path)
        build_file_path = pathlib.Path(build_dir_path, template_path.name) # Built yaml name must be <domain>.yaml
        logging.info(f"Building {template_path} to {build_file_path}...")
        with open(template_path, 'r') as template, open(build_file_path, 'w') as out:
            lines = template.read().splitlines(keepends=True) # keepends=True to keep the newline characters
            def substitute_template_vars(line):
                #logging.debug(f"Substituting template vars for line: {line}")
                def replace_template_var(match):
                    key = match.group(1) # Get the value inside the brackets
                    tokens = key.split(sep='.')
                    value_imperative = data
                    for token in tokens:
                        try:
                            value_imperative = value_imperative[token]
                        except KeyError:
                            raise TemplateVarKeyError(key)
                    return value_imperative
                return template_pattern.sub(replace_template_var, line)
            generated_lines = map(substitute_template_vars, lines)
            for line in generated_lines:
                out.write(line)
        logging.info(f"Finished building {template_path} to {build_file_path}")
    for filepath in get_files():
        build_octodns_config_from_yaml_template(filepath, data)
    logging.info("Finished building yaml files for octodns")

def read_generated_json():
    data = {}
    try:
        with open(share.generated_nixie_path, 'r') as file:
            data['nixie'] = json.load(file)
    except OSError as e:
        logging.error(f"Ignoring generated nixie json: {e}")
    try:
        with open(share.generated_serverref_path, 'r') as file:
            data['serverref'] = json.load(file)
    except OSError as e:
        logging.error(f"Ignoring generated serverref json: {e}")
    return data

def main():
    inject_data_into_octodns_templates(read_generated_json())

if __name__ == "__main__":
    main()