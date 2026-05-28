#!/usr/bin/env python3
"""
Extract all secrets, environment variables, and configuration from homelab-infra project
Outputs a comprehensive YAML backup file for safe-keeping
"""

import os
import yaml
import sys
from pathlib import Path
from typing import Dict, List, Set, Any
from collections import defaultdict

def extract_environment_variables() -> Dict[str, Any]:
    """Extract all environment variables from k8s deployment files"""
    env_vars = defaultdict(list)
    k8s_dir = Path("k8s")

    for yaml_file in k8s_dir.rglob("*.yaml"):
        try:
            with open(yaml_file, 'r') as f:
                content = yaml.safe_load_all(f)
                for doc in content:
                    if not doc:
                        continue

                    # Look for containers with env vars
                    if doc.get('kind') in ['Deployment', 'StatefulSet', 'DaemonSet', 'Job', 'CronJob']:
                        spec = doc.get('spec', {})
                        # Handle Job/CronJob which have jobTemplate
                        if 'jobTemplate' in spec:
                            spec = spec['jobTemplate'].get('spec', {})

                        template_spec = spec.get('template', {}).get('spec', {})
                        containers = template_spec.get('containers', [])

                        for container in containers:
                            env_list = container.get('env', [])
                            for env in env_list:
                                env_name = env.get('name')
                                env_value = env.get('value')
                                secret_ref = env.get('valueFrom', {}).get('secretKeyRef')
                                config_ref = env.get('valueFrom', {}).get('configMapKeyRef')

                                entry = {
                                    'name': env_name,
                                    'file': str(yaml_file.relative_to('.')),
                                    'namespace': doc['metadata'].get('namespace', 'default')
                                }

                                if env_value:
                                    entry['value'] = env_value
                                if secret_ref:
                                    entry['secretRef'] = secret_ref
                                if config_ref:
                                    entry['configMapRef'] = config_ref

                                env_vars[f"{env_name}"].append(entry)
        except Exception as e:
            print(f"Warning: Error parsing {yaml_file}: {e}", file=sys.stderr)

    return dict(env_vars)

def extract_secret_references() -> Dict[str, List[Dict]]:
    """Extract all Secret references and requirements"""
    secrets = defaultdict(list)
    k8s_dir = Path("k8s")

    for yaml_file in k8s_dir.rglob("*.yaml"):
        try:
            with open(yaml_file, 'r') as f:
                content = yaml.safe_load_all(f)
                for doc in content:
                    if not doc:
                        continue

                    if doc.get('kind') == 'Secret':
                        secret_name = doc['metadata'].get('name')
                        namespace = doc['metadata'].get('namespace', 'default')
                        secret_type = doc.get('type', 'Opaque')
                        keys = list(doc.get('data', {}).keys()) if doc.get('data') else []

                        secrets[secret_name].append({
                            'namespace': namespace,
                            'type': secret_type,
                            'keys': keys,
                            'file': str(yaml_file.relative_to('.')),
                            'source': 'manifest'
                        })

                    # Look for secretKeyRef in containers
                    if doc.get('kind') in ['Deployment', 'StatefulSet', 'DaemonSet', 'Pod', 'Job', 'CronJob']:
                        spec = doc.get('spec', {})
                        if 'jobTemplate' in spec:
                            spec = spec['jobTemplate'].get('spec', {})

                        template_spec = spec.get('template', {}).get('spec', {})
                        containers = template_spec.get('containers', [])

                        for container in containers:
                            env_list = container.get('env', [])
                            for env in env_list:
                                secret_ref = env.get('valueFrom', {}).get('secretKeyRef')
                                if secret_ref:
                                    secret_name = secret_ref.get('name')
                                    key = secret_ref.get('key')

                                    if secret_name and key:
                                        secrets[secret_name].append({
                                            'namespace': doc['metadata'].get('namespace', 'default'),
                                            'requiredKey': key,
                                            'usedBy': f"{doc['metadata'].get('name')} ({doc.get('kind')})",
                                            'file': str(yaml_file.relative_to('.')),
                                            'source': 'reference'
                                        })
        except Exception as e:
            print(f"Warning: Error parsing {yaml_file}: {e}", file=sys.stderr)

    return dict(secrets)

def extract_configmap_references() -> Dict[str, List[Dict]]:
    """Extract all ConfigMap references and requirements"""
    configmaps = defaultdict(list)
    k8s_dir = Path("k8s")

    for yaml_file in k8s_dir.rglob("*.yaml"):
        try:
            with open(yaml_file, 'r') as f:
                content = yaml.safe_load_all(f)
                for doc in content:
                    if not doc:
                        continue

                    if doc.get('kind') == 'ConfigMap':
                        cm_name = doc['metadata'].get('name')
                        namespace = doc['metadata'].get('namespace', 'default')
                        keys = list(doc.get('data', {}).keys()) if doc.get('data') else []

                        configmaps[cm_name].append({
                            'namespace': namespace,
                            'keys': keys,
                            'file': str(yaml_file.relative_to('.')),
                            'source': 'manifest'
                        })

                    # Look for configMapKeyRef in containers
                    if doc.get('kind') in ['Deployment', 'StatefulSet', 'DaemonSet', 'Pod', 'Job', 'CronJob']:
                        spec = doc.get('spec', {})
                        if 'jobTemplate' in spec:
                            spec = spec['jobTemplate'].get('spec', {})

                        template_spec = spec.get('template', {}).get('spec', {})
                        containers = template_spec.get('containers', [])

                        for container in containers:
                            env_list = container.get('env', [])
                            for env in env_list:
                                cm_ref = env.get('valueFrom', {}).get('configMapKeyRef')
                                if cm_ref:
                                    cm_name = cm_ref.get('name')
                                    key = cm_ref.get('key')

                                    if cm_name and key:
                                        configmaps[cm_name].append({
                                            'namespace': doc['metadata'].get('namespace', 'default'),
                                            'requiredKey': key,
                                            'usedBy': f"{doc['metadata'].get('name')} ({doc.get('kind')})",
                                            'file': str(yaml_file.relative_to('.')),
                                            'source': 'reference'
                                        })
        except Exception as e:
            print(f"Warning: Error parsing {yaml_file}: {e}", file=sys.stderr)

    return dict(configmaps)

def extract_cluster_config() -> Dict[str, Any]:
    """Extract cluster configuration from ansible apply-secrets.yml"""
    cluster_config = {}

    apply_secrets_file = Path("ansible/apply-secrets.yml")
    if apply_secrets_file.exists():
        try:
            with open(apply_secrets_file, 'r') as f:
                content = yaml.safe_load(f)
                if isinstance(content, list) and len(content) > 0:
                    task = content[0]
                    cluster_config = task.get('vars', {}).get('cluster_config', {})
        except Exception as e:
            print(f"Warning: Error parsing {apply_secrets_file}: {e}", file=sys.stderr)

    return cluster_config

def extract_ansible_vars() -> Dict[str, Any]:
    """Extract variables from ansible files"""
    ansible_vars = {}

    for ansible_file in Path("ansible").glob("*.yml"):
        try:
            with open(ansible_file, 'r') as f:
                content = yaml.safe_load(f)
                if isinstance(content, list):
                    for task in content:
                        if isinstance(task, dict) and 'vars' in task:
                            ansible_vars[ansible_file.name] = task['vars']
        except Exception as e:
            print(f"Warning: Error parsing {ansible_file}: {e}", file=sys.stderr)

    return ansible_vars

def main():
    print("Extracting secrets and configuration...", file=sys.stderr)

    # Change to project directory
    os.chdir(Path(__file__).parent)

    # Extract all data
    env_vars = extract_environment_variables()
    secrets = extract_secret_references()
    configmaps = extract_configmap_references()
    cluster_config = extract_cluster_config()
    ansible_vars = extract_ansible_vars()

    # Build output structure
    output = {
        'metadata': {
            'description': 'Homelab Infrastructure - Secrets and Configuration Backup',
            'date': str(Path('README.md').stat().st_mtime),
            'note': 'This file contains references to all secrets, configuration, and environment variables. Store securely.'
        },
        'cluster_configuration': cluster_config,
        'environment_variables': env_vars,
        'secrets': secrets,
        'configmaps': configmaps,
        'ansible_variables': ansible_vars,
        'instructions': {
            'secrets_storage': 'Secrets are stored in /mnt/nas/homelab/secrets.yaml on the NAS',
            'apply_command': 'ansible-playbook -i ansible/inventory.ini ansible/apply-secrets.yml',
            'restore_warning': 'Before rebuilding, ensure /mnt/nas/homelab/secrets.yaml is backed up'
        }
    }

    # Output as YAML
    print(yaml.dump(output, default_flow_style=False, sort_keys=False))

if __name__ == '__main__':
    main()
