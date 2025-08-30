"""A DigitalOcean Python Pulumi program"""

import json
import pulumi
import pulumi_digitalocean as do
import os
import pathlib
import re
import app.src.share as share
from app.src.share import logging

#pulumi_config = pulumi.Config()
#do_token = pulumi_config.require_object('token')

share.get_cwd() # Validate that CWD is correct

ssh_public_keys = [
    42072822, # Yuto's Sodium
    40513323, # My Tilde
]

tag_pulumi_taco = do.Tag("pulumi-taco", opts=pulumi.ResourceOptions(retain_on_delete=True, protect=True))

image_nixos_23_11_x86_64 = do.CustomImage("nixos-23_11-x86_64",
    opts=pulumi.ResourceOptions(retain_on_delete=True, protect=True), # Prevent accidental deletion
    url="https://cloudflare-ipfs.com/ipfs/QmUtF6u4TDZCXVVrk16VDw5Ag2iHhrwVV27EJ461TGcWun?filename=nixos-23.11-x86_64.qcow2.gz",
    regions=["sfo3"],
    tags=[tag_pulumi_taco])

image_nixos_yuto = do.CustomImage("nixos-yuto3",
    url="https://cloudflare-ipfs.com/ipfs/QmRvjvpyutQSCGxkEqK5BJWirpS9jMZTXvyAy8rPryv2mr?filename=nixos-yuto3.qcow2.gz",
    regions=["sfo3"],
    tags=[tag_pulumi_taco])

nixie = do.Droplet("nixie",
    image=image_nixos_yuto,
    region=do.Region.SFO3,
    size=do.DropletSlug.DROPLET_S1_VCPU1_GB,
    ssh_keys=ssh_public_keys,
    tags=[tag_pulumi_taco])

serverref = do.Droplet("andref",
    image=image_nixos_yuto,
    region=do.Region.SFO3,
    size="s-1vcpu-1gb-35gb-intel", #do.DropletSlug.DROPLET_S1_VCPU1_GB,
    ssh_keys=ssh_public_keys,
    tags=[tag_pulumi_taco])

volume_serverref_nix_store = do.Volume("serverref-nix-store",
    region=do.Region.SFO3,
    size=100,
    initial_filesystem_type="ext4",
    tags=[tag_pulumi_taco])


attachment_serverref_nix_store = do.VolumeAttachment("attach-serverref-nix-store",
    droplet_id=serverref.id,
    volume_id=volume_serverref_nix_store.id)

def callback(args):
    print("Volume ID", args['volume_id'])
    #print("Volume URN", args['volume_urn'])
    #print("Volume Filesystem Label", args['volume_filesystem_label'])
    print("Volume Name", args['volume_name'])
    print("Attachment ID", args['attachment_id'])
pulumi.Output.all(
    volume_id=volume_serverref_nix_store.id,
    volume_urn=volume_serverref_nix_store.volume_urn,
    volume_name=volume_serverref_nix_store.name,
    attachment_id=attachment_serverref_nix_store.id,
    #volume_fs_label=volume_serverref_nix_store.filesystem_label, # Breaks this thread for some reason
).apply(callback)

generated_data = pulumi.Output.all(
        # List all values to need to be awaited on here
        nixie_ipv4_address=nixie.ipv4_address,
        serverref_ipv4_address=serverref.ipv4_address,
        volume_serverref_nix_store=volume_serverref_nix_store.name,
    ).apply(lambda args: {
        'nixie': {
            'name': 'nixie',
            'ipAddress': args['nixie_ipv4_address'],
        },
        'serverref': {
            'name': 'serverref',
            'ipAddress': args['serverref_ipv4_address'],
            'nix-store-volume': args['volume_serverref_nix_store'],
        },
    })

# TODO: rename this fn
def write_dict_to_json_at(data, file_path):
    logging.info(f"Writing data to {file_path}...")
    with open(file_path, 'w', encoding='utf-8') as file:
        json.dump(data, file, ensure_ascii=False, indent="    ")
    logging.info(f"Finished writing data to {file_path}")

def on_generated_data_complete(data):
    logging.info("Data finished generating")
    logging.debug(f"Data: {data}")
    write_dict_to_json_at(data, share.generated_json_path)

# The lambda will run once the value in `generated_data` (an async variable) is available
generated_data.apply(on_generated_data_complete)

# Export the name of the domain
pulumi.export('tag_pulumi_taco', tag_pulumi_taco)
pulumi.export('image_test', image_nixos_23_11_x86_64)
pulumi.export('image_nixos_yuto', image_nixos_yuto)
pulumi.export('droplet_nixie', nixie)
pulumi.export('droplet_serverref', serverref)
pulumi.export('volume_serverref_nix_store', volume_serverref_nix_store)
pulumi.export('attachment_serverref_nix_store', attachment_serverref_nix_store)