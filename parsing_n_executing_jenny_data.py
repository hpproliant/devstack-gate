import os
import subprocess
import sys

ci_job_referencing_data = {
    'drivers': {
        'env_var_key': 'ILO_DRIVER',

        'a': 'pxe_ilo',
        'b': 'iscsi_ilo',
        'c': 'agent_ilo',
    },
    'boot_modes': {
        'env_var_key': 'BOOT_MODE',

        'a': 'bios',
        'b': 'uefi',
    },
    'boot_options': {
        'env_var_key': 'BOOT_OPTION',

        'a': 'netboot',
        'b': 'local',
    },
    'whole_disk_image?': {
        'env_var_key': 'IRONIC_DEPLOY_WITH_WHOLE_DISK_IMAGE',

        'a': 'True',
        'b': 'False',
    },
    'secure_boot?': {
        'env_var_key': 'SECURE_BOOT',

        'a': 'true',
        'b': 'false',
    },
    'platforms': {
        'env_var_key': 'ILO_HWINFO',

        # Gen8
        'a': os.environ.get('ILO_HWINFO_GEN8_SYSTEM'),
        # Gen9
        'b': os.environ.get('ILO_HWINFO_GEN9_SYSTEM'),
    },
}

case_to_component_mapper = {
    '1': 'drivers',
    '2': 'boot_modes',
    '3': 'boot_options',
    '4': 'whole_disk_image?',
    '5': 'secure_boot?',
    '6': 'platforms',
}

def get_component(case_number):
    return case_to_component_mapper.get(case_number)


def get_env_var_instruction(token):
    component_string = get_component(token[0])
    component = ci_job_referencing_data.get(component_string)
    return 'export ' + component.get('env_var_key') + '=' + component.get(token[1])


# option_string = "1a     2b     3b     4b     5b     6b"
# option_string = "1b     2a     3b     4a     5b     6a"
# option_string = "1c     2b     3b     4a     5a     6b"
# option_string = "1b     2b     3a     4b     5a     6b"
# option_string = "1a     2a     3a     4b     5b     6a"
# option_string = "1c     2a     3b     4a     5b     6a"
# option_string = "1a     2b     3b     4a     5a     6b"
# option_string = "1a     2a     3b     4b     5b     6b"
option_string = sys.argv[1]

def get_shell_instruction():
    option_tokens = option_string.split()
    complete_instruction = ''
    for token in option_tokens:
        env_var_set_instruction = get_env_var_instruction(token)
        complete_instruction += env_var_set_instruction + ';'
    return complete_instruction


if __name__ == '__main__':
    print get_shell_instruction()

