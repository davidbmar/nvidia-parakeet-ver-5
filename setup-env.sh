#!/bin/bash
#
# Setup Environment Configuration
# Creates .env from .env.example template
#

set -e

echo "🔧 NVIDIA Parakeet ASR - Environment Setup"
echo "==========================================="

# Check if .env already exists
if [[ -f .env ]]; then
    echo ""
    echo "⚠️  .env file already exists!"
    echo ""
    echo "Options:"
    echo "  1. Backup existing .env and create new one"
    echo "  2. Keep existing .env (recommended)"
    echo "  3. Exit"
    echo ""
    read -p "Choose option (1/2/3): " choice
    
    case $choice in
        1)
            backup_name=".env.backup.$(date +%Y%m%d_%H%M%S)"
            mv .env "$backup_name"
            echo "✅ Existing .env backed up as: $backup_name"
            ;;
        2)
            echo "✅ Keeping existing .env file"
            exit 0
            ;;
        3)
            echo "❌ Setup cancelled"
            exit 1
            ;;
        *)
            echo "❌ Invalid option"
            exit 1
            ;;
    esac
fi

# Check if .env.example exists
if [[ ! -f .env.example ]]; then
    echo "❌ .env.example template file not found!"
    echo "   This file should be in the repository."
    exit 1
fi

# Copy template to .env
cp .env.example .env

echo ""
echo "✅ Created .env from .env.example template"
echo ""
echo "🔐 SECURITY WARNING:"
echo "   The .env file contains sensitive information!"
echo "   • Never commit .env to git"
echo "   • Update the placeholder values with your real configuration"
echo ""
echo "📝 Required values to update in .env:"
echo "   • NGC_API_KEY - Get from ngc.nvidia.com"
echo "   • AWS_ACCOUNT_ID - Your AWS account ID"
echo "   • SSH_KEY_NAME - Name of your EC2 key pair"
echo "   • SSH_KEY_PATH - Path to your private key file"
echo "   • AUTHORIZED_IPS_LIST - Your IP address for security group"
echo ""
echo "🔧 Edit .env now? (y/N)"
read -p "> " edit_now

if [[ "$edit_now" == "y" || "$edit_now" == "Y" ]]; then
    if command -v nano >/dev/null 2>&1; then
        nano .env
    elif command -v vim >/dev/null 2>&1; then
        vim .env
    else
        echo "Please edit .env manually with your preferred editor"
    fi
fi

echo ""
echo "🎉 Environment setup complete!"
echo "   You can now run the deployment scripts."
echo ""