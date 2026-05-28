#!/usr/bin/env python3

"""
Extract ALL live secrets from Kubernetes cluster.

This script connects to your cluster and exports every secret currently stored,
including those created manually via kubectl commands.

USAGE:
  ssh homelab@172.20.20.3
  cd /path/to/homelab-infra
  python3 extract-live-secrets.py

OUTPUT: secrets-live-backup-TIMESTAMP.yaml
"""

import subprocess
import sys
import json
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
        self.secrets = []
        self.configmaps = []
        self.total_secrets = 0
        self.total_configmaps = 0

    def check_prerequisites(self):
        """Check if kubectl is available and kubeconfig exists."""
        # Check kubeconfig
        if not Path(self.kubeconfig).exists():
            print(f"❌ ERROR: kubeconfig not found at {self.kubeconfig}")
            sys.exit(1)

        # Check kubectl
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
            print(f"❌ Error running kubectl: {e.stderr}")
            sys.exit(1)

    def get_namespaces(self):
        """Get list of all namespaces."""
        output = self.run_kubectl("get", "namespaces", "-o", "jsonpath={.items[*].metadata.name}")
        return output.split()

    def extract_secrets_from_namespace(self, namespace):
        """Extract all secrets from a namespace."""
        try:
            output = self.run_kubectl("get", "secrets", "-n", namespace, "-o", "yaml")
            if output.strip():
                data = yaml.safe_load(output)
                if data and "items" in data:
                    count = len(data["items"])
                    self.total_secrets += count
                    print(f"  ✓ Found {count} secret(s)")
                    return data["items"]
        except Exception as e:
            print(f"  ⚠️  Error extracting secrets: {e}")
        return []

    def extract_configmaps_from_namespace(self, namespace):
        """Extract all configmaps from a namespace."""
        try:
            output = self.run_kubectl("get", "configmaps", "-n", namespace, "-o", "yaml")
            if output.strip():
                data = yaml.safe_load(output)
                if data and "items" in data:
                    count = len(data["items"])
                    self.total_configmaps += count
                    print(f"  ✓ Found {count} ConfigMap(s)")
                    return data["items"]
        except Exception as e:
            print(f"  ⚠️  Error extracting configmaps: {e}")
        return []

    def extract_all(self):
        """Extract all secrets and configmaps from all namespaces."""
        print("╔══════════════════════════════════════════════════════════════════════════════╗")
        print("║         Extracting ALL Live Secrets from Kubernetes Cluster                  ║")
        print("╚══════════════════════════════════════════════════════════════════════════════╝")
        print()
        print(f"Using kubeconfig: {self.kubeconfig}")
        print(f"Output file: {self.output_file}")
        print()

        # Check prerequisites
        self.check_prerequisites()

        # Get namespaces
        print("🔍 Discovering namespaces...")
        namespaces = self.get_namespaces()
        print(f"Found {len(namespaces)} namespace(s): {', '.join(namespaces)}")
        print()

        # Extract from each namespace
        for namespace in namespaces:
            print(f"📦 Processing namespace: {namespace}")

            # Extract secrets
            secrets = self.extract_secrets_from_namespace(namespace)
            self.secrets.extend(secrets)

            # Extract configmaps
            configmaps = self.extract_configmaps_from_namespace(namespace)
            self.configmaps.extend(configmaps)

        return self.secrets, self.configmaps

    def write_output(self):
        """Write all extracted resources to YAML file."""
        # Create manifest structure
        manifest = {
            "apiVersion": "v1",
            "kind": "List",
            "metadata": {
                "name": "all-secrets-configmaps-backup",
                "namespace": "default"
            },
            "items": self.secrets + self.configmaps
        }

        # Write to file
        with open(self.output_file, "w") as f:
            # Add header
            f.write("""################################################################################
# LIVE KUBERNETES SECRETS & CONFIGMAPS BACKUP
#
# This file contains ALL secrets and configmaps currently stored in your cluster.
# These include:
#   - Manually created secrets (via kubectl)
#   - Secrets from bootstrapping
#   - Generated secrets (TLS certs, etc)
#   - All application secrets
#   - ConfigMaps with sensitive configuration
#
# SECURITY: Store this file securely. It contains encoded secret values.
#
# RESTORE INSTRUCTIONS:
#   kubectl apply -f secrets-live-backup-TIMESTAMP.yaml
#
# RESTORE WARNING:
#   This will overwrite existing secrets/configmaps with the same name.
#   Ensure no important data will be lost before applying.
#
################################################################################

""")
            # Write YAML
            yaml.dump(manifest, f, default_flow_style=False, sort_keys=False)

    def validate(self):
        """Validate the output file."""
        try:
            with open(self.output_file, "r") as f:
                yaml.safe_load(f)
            print("✓ YAML is valid")
            return True
        except Exception as e:
            print(f"⚠️  YAML validation error: {e}")
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

        # Validate
        print("🔍 Validating YAML...")
        self.validate()
        print()

        # File size
        file_size = Path(self.output_file).stat().st_size
        print(f"📋 File size: {file_size:,} bytes ({file_size/1024:.1f} KB)")
        print()

        # Sample content
        print("📝 Sample content (first secret):")
        print("---")
        if self.secrets:
            print(yaml.dump(self.secrets[0], default_flow_style=False))
        else:
            print("(no secrets found)")
        print()

        # Security notes
        self._print_security_notes()

    def _print_security_notes(self):
        """Print security recommendations."""
        print("🔐 SECURITY NOTES:")
        print("  1. This file contains encoded secrets - handle with care")
        print("  2. Store securely (not in public repos)")
        print("  3. Consider encrypting before storing off-cluster:")
        print()
        print(f"     # Encrypt the backup")
        print(f"     gpg --encrypt --recipient YOUR_EMAIL {self.output_file}")
        print()
        print(f"     # Decrypt when needed")
        print(f"     gpg --decrypt {self.output_file}.gpg > {self.output_file}")
        print()
        print("🔄 TO RESTORE TO A NEW CLUSTER:")
        print("  1. Ensure new cluster has all required namespaces")
        print("  2. Apply the backup:")
        print(f"     kubectl apply -f {self.output_file}")
        print("  3. Verify restoration:")
        print("     kubectl get secrets --all-namespaces")
        print("     kubectl get configmaps --all-namespaces")
        print()
        print("📦 Next steps:")
        print(f"  1. Review the generated file for sensitive data")
        print(f"  2. Move to a secure location (NAS, backup system)")
        print(f"  3. Consider encrypting with GPG")
        print(f"  4. Test restore procedure in staging before production rebuild")
        print()

    def run(self):
        """Run the complete extraction process."""
        try:
            # Extract
            self.extract_all()

            # Write output
            self.write_output()

            # Print summary
            self.print_summary()

            print(f"✨ Secrets backup saved to: {self.output_file}")

        except Exception as e:
            print(f"❌ ERROR: {e}")
            sys.exit(1)


def main():
    """Main entry point."""
    # Optional: specify kubeconfig path via environment or argument
    kubeconfig = os.environ.get("KUBECONFIG", "/etc/rancher/k3s/k3s.yaml")

    if len(sys.argv) > 1:
        kubeconfig = sys.argv[1]

    extractor = KubernetesSecretsExtractor(kubeconfig)
    extractor.run()


if __name__ == "__main__":
    main()
