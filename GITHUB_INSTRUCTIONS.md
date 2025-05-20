# Pushing to GitHub

Follow these steps to push your repository to GitHub:

1. Create a new repository on GitHub:
   - Go to https://github.com/new
   - Name: `dvd-bluray-ripper`
   - Description: "Automated DVD and Blu-ray ripping scripts for Plex media server"
   - Set visibility (public recommended for open source)
   - Do NOT initialize with README, .gitignore, or license (we already have these)
   - Click "Create repository"

2. Connect your local repository to GitHub (replace `yourusername` with your actual GitHub username):
   ```bash
   cd /home/traxx/dvd-bluray-ripper-github
   git remote add origin https://github.com/yourusername/dvd-bluray-ripper.git
   ```

3. Push your code to GitHub:
   ```bash
   git push -u origin main
   ```

4. Verify your repository is now on GitHub:
   - Visit https://github.com/yourusername/dvd-bluray-ripper

## Optional: Installing GitHub CLI

For easier GitHub management in the future, you can install GitHub CLI:

```bash
# For Ubuntu/Debian
sudo apt install gh

# For CentOS/RHEL
sudo dnf install gh

# For Arch Linux
sudo pacman -S github-cli
```

Then authenticate:
```bash
gh auth login
```

With GitHub CLI installed, you could have created and pushed the repository with:
```bash
gh repo create dvd-bluray-ripper --public --source=. --push
```