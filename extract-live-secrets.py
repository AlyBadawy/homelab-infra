#!/usr/bin/env python3

"""
Extract ALL live secrets from Kubernetes cluster.

Produces clean YAML documents that can be directly applied with:
  kubectl apply -f secrets-live-backup-TIMESTAMP.yaml

USAGE:
  ssh homelab@172.20.20.3
  cd /path/to/homelab-infra
  python3 extract-live-secrets.py

OUTPUT: secrets-live-backup-TIMESTAMP.yaml
"""

import subprocess
import sys
import yaml
from datetime import datetime
from pathlib import Path
import os

class KubernetesSecretsExtractor:
    def __init__(self, kubeconfig=None):
        """Initialize with optional kubeconfig path."""
        self.kubeconfig = kubeconfig or "/etc/rancher/k3s/k3s.yaml"
        self.timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        self.output_file = f"secrets-live-backup-{self.timestamp}.yaml"
        self.documents = []
        self.total_secrets = 0
        self.total_configmaps = 0

    def check_prerequisites(self):
        """Check if kubectl is available and kubeconfig exists."""
        if not Path(self.kubeconfig).exists():
            print(f"❌ ERROR: kubeconfig not found at {self.kubeconfig}")
            sys.exit(1)

        try:
            subprocess.run(["kubectl", "version", "--short"],
                          capture_output=True, check=True)
        except (FileNotFoundError, subprocess.CalledProcessError):
            print("❌ ERROR: kubectl not found or not working")
            sys.exit(1)

    def run_kubectl(self, *args):
        """Run kubectl command with kubeconfig."""
        cmd = ["kubectl", f"--kubeconfig={self.kubeconfig}"] + list(args)
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, check=True)
            return result.stdout
        except subprocess.CalledProcessError as e:
            print(f"❌ Error running kubectl: {e.stderr}", file=sys.stderr)
            return None

    def get_namespaces(self):
        """Get list of all namespaces."""
        output = self.run_kubectl("get", "namespaces", "-o", "jsonpath={.items[*].metadata.name}")
        if output:
            return output.split()
        return []

    def should_skip_secret(self, secret_name):
        """Skip default and helm-managed secrets."""
        if secret_name.startswith("default-token-"):
            return True
        if secret_name.startswith("sh.helm.release"):
            return True
        if secret_name.startswith("builder-dockercfg-"):
            return True
        return False

    def extract_secrets_from_namespace(self, namespace):
        """Extract all secrets from a namespace."""
        try:
            output = self.run_kubectl("get", "secrets", "-n", namespace, "-o", "json")
            if output:
                data = yaml.safe_load(output)
                if data and "items" in data:
                    secrets = data["items"]
                    filtered_secrets = []

                    for secret in secrets:
                        secret_name = secret.get("metadata", {}).get("name", "")
                        if not self.should_skip_secret(secret_name):
                            filtered_secrets.append(secret)
                            self.documents.append(secret)
                            self.total_secrets += 1

                    if filtered_secrets:
                        print(f"  ✓ Found {len(filtered_secrets)} secret(s)")
        except Exception as e:
            print(f"  ⚠️  Error extracting secrets: {e}", file=sys.stderr)

    def extract_configmaps_from_namespace(self, namespace):
        """Extract all configmaps from a namespace."""
        try:
            output = self.run_kubectl("get", "configmaps", "-n", namespace, "-o", "json")
            if output:
                data = yaml.safe_load(output)
                if data and "items" in data:
                    configmaps = data["items"]

                    for cm in configmaps:
                        cm_name = cm.get("metadata", {}).get("name", "")
                        # Skip kube-root-ca.crt which is auto-generated
                        if cm_name == "kube-root-ca.crt":
                            continue
                        self.documents.append(cm)
                        self.total_configmaps += 1

                    if configmaps:
                        print(f"  ✓ Found {len(configmaps)} ConfigMap(s)")
        except Exception as e:
            print(f"  ⚠️  Error extracting configmaps: {e}", file=sys.stderr)

    def extract_all(self):
        """Extract all secrets and configmaps from all namespaces."""
        print("╔══════════════════════════════════════════════════════════════════════════════╗")
        print("║         Extracting ALL Live Secrets from Kubernetes Cluster                  ║")
        print("╚══════════════════════════════════════════════════════════════════════════════╝")
        print()
        print(f"Using kubeconfig: {self.kubeconfig}")
        print(f"Output file: {self.output_file}")
        print()

        self.check_prerequisites()

        print("🔍 Discovering namespaces...")
        namespaces = self.get_namespaces()
        print(f"Found {len(namespaces)} namespace(s): {', '.join(namespaces)}")
        print()

        for namespace in namespaces:
            print(f"📦 Processing namespace: {namespace}")
            self.extract_secrets_from_namespace(namespace)
            self.extract_configmaps_from_namespace(namespace)

    def write_output(self):
        """Write all extracted resources as YAML documents."""
        with open(self.output_file, "w") as f:
            # Write header
            f.write("""################################################################################
# LIVE KUBERNETES SECRETS & CONFIGMAPS BACKUP
#
# This file contains ALL secrets and configmaps currently stored in your cluster.
# It can be directly applied to a new cluster with:
#   kubectl apply -f secrets-live-backup-TIMESTAMP.yaml
#
# SECURITY: Store this file securely. It contains encoded secret values.
#
################################################################################

""")

            # Write each document separately
            for i, doc in enumerate(self.documents):
                if i > 0:
                    f.write("---\n")
                yaml.dump(doc, f, default_flow_style=False, sort_keys=False)

    def validate(self):
        """Validate the output file can be applied."""
        try:
            result = subprocess.run(
                ["kubectl", "--kubeconfig", self.kubeconfig, "apply",
                 "-f", self.output_file, "--dry-run=client"],
                capture_output=True, text=True, check=True
            )
            print("✓ YAML is valid and can be applied to cluster")
            return True
        except Exception as e:
            print(f"⚠️  Validation error: {e}")
            return False

    def print_summary(self):
        """Print extraction summary."""
        print()
        print("✅ Extraction complete!")
        print()
        print("Summary:")
        print(f"  📊 Total Secrets: {self.total_secrets}")
        print(f"  📊 Total ConfigMaps: {self.total_configmaps}")
        print(f"  📄 Output file: {self.output_file}")
        print()

        print("🔍 Validating YAML...")
        self.validate()
        print()

        file_size = Path(self.output_file).stat().st_size
        print(f"📋 File size: {file_size:,} bytes ({file_size/1024:.1f} KB)")
        print()

        print("🔐 SECURITY:")
        print("  Encrypt with GPG:")
        print(f"    gpg --encrypt --recipient your-email {self.output_file}")
        print()

        print("🔄 TO RESTORE:")
        print(f"  kubectl apply -f {self.output_file}")
        print()

        print("✨ Done! File is ready to use.")

    def run(self):
        """Run the complete extraction process."""
        try:
            self.extract_all()
            self.write_output()
            self.print_summary()
        except Exception as e:
            print(f"❌ ERROR: {e}")
            sys.exit(1)


def main():
    """Main entry point."""
    kubeconfig = os.environ.get("KUBECONFIG", "/etc/rancher/k3s/k3s.yaml")
    if len(sys.argv) > 1:
        kubeconfig = sys.argv[1]

    extractor = KubernetesSecretsExtractor(kubeconfig)
    extractor.run()


if __name__ == "__main__":
    main()
