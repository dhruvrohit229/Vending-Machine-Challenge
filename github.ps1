#Requires -Version 7
$ErrorActionPreference = "Stop"

# Bypass execution policy to avoid permission issues
try {
    Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force -ErrorAction Stop | Out-Null
    Write-Host "✅ Execution policy set to Bypass for this session" -ForegroundColor Green
} catch {
    Write-Host "⚠️ Could not set execution policy. You may need to run: powershell -ExecutionPolicy Bypass -File .\submit.ps1" -ForegroundColor Yellow
}

function Say($message) { Write-Host "`n$message" }

function Get-SmartInput([string]$prompt, [bool]$allowEmpty = $false) {
  do {
    Write-Host "$prompt" -NoNewline
    $input = ""
    $startTime = Get-Date
    
    # Read input character by character to detect paste
    while ($true) {
      $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
      
      if ($key.VirtualKeyCode -eq 13) { # Enter key
        break
      } elseif ($key.VirtualKeyCode -eq 8) { # Backspace
        if ($input.Length -gt 0) {
          $input = $input.Substring(0, $input.Length - 1)
          Write-Host "`b `b" -NoNewline
        }
      } elseif ($key.Character -match '[^\x00-\x1F]') { # Printable character
        $input += $key.Character
        Write-Host $key.Character -NoNewline
        
        # Check if this looks like a paste (multiple chars in short time)
        $currentTime = Get-Date
        if (($currentTime - $startTime).TotalMilliseconds -lt 100 -and $input.Length -gt 10) {
          # Likely a paste, auto-process after brief delay
          Start-Sleep -Milliseconds 200
          break
        }
      }
    }
    
    Write-Host "" # New line
    
    if (-not $allowEmpty -and [string]::IsNullOrWhiteSpace($input)) {
      Write-Host "❌ Input cannot be empty. Please try again." -ForegroundColor Red
    }
  } while (-not $allowEmpty -and [string]::IsNullOrWhiteSpace($input))
  
  return $input.Trim()
}

function Get-PlainTextFromSecureString([Security.SecureString]$secure) {
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
  try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Mask-Token([string]$token) {
  if (-not $token) { return "(empty)" }
  if ($token.Length -le 7) { return ("*" * $token.Length) }
  return ($token.Substring(0,4) + "..." + $token.Substring($token.Length-3))
}

function Ensure-Git() {
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "❌ git not found. Please install Git and try again."; exit 1
  }
}

# ---------------- Container Config ----------------
$IMG  = "abxglia/speedrun-stylus:0.1"
$NAME = "speedrun-stylus"
$PORT = 3000

function Ensure-Docker() {
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Host "❌ Docker not found. Install Docker Desktop."; exit 1
  }
  try { docker info | Out-Null } catch { Write-Host "❌ Docker daemon not running. Start Docker Desktop."; exit 1 }
}

function Ensure-Container() {
  $inspect = docker inspect -f '{{.State.Status}}' $NAME 2>$null
  if ($LASTEXITCODE -eq 0) {
    $status = $inspect.Trim()
    if ($status -eq 'running') {
      Say "♻️ Container '$NAME' already running; reusing."
    } else {
      Say "▶️ Starting existing container '$NAME'..."
      docker start $NAME | Out-Null
    }
  } else {
    Say "🚀 Starting container..."
    docker run -d --name $NAME `
      -v ${PWD}:/app `
      -v speedrun-yarn-cache:/root/.cache/yarn `
      -v speedrun-cargo-registry:/root/.cargo/registry `
      -v speedrun-cargo-git:/root/.cargo/git `
      -v speedrun-rustup:/root/.rustup `
      -v speedrun-foundry:/root/.foundry `
      -p "$PORT`:3000" `
      $IMG tail -f /dev/null | Out-Null
  }
}

function Select-ChallengeBranch() {
  Write-Host "Choose a challenge (for branch selection):
1) counter
2) nft
3) vending-machine
4) multi-sig
5) stylus-uniswap"
  $choice = Read-Host "Enter 1-5"
  switch ($choice) {
    "1" { return "counter" }
    "2" { return "nft" }
    "3" { return "vending-machine" }
    "4" { return "multi-sig" }
    "5" { return "stylus-uniswap" }
    default { Write-Host "Invalid choice."; exit 1 }
  }
}

function Find-RepoPath([string]$branch) {
  # Simple approach: just find any directory with .git
  $candidates = @(
    "/app",
    "/app/speedrun-$branch", 
    "/app/test-vending"
  )
  
  foreach ($candidate in $candidates) {
    $hasGit = docker exec $NAME test -d "$candidate/.git" 2>$null
    if ($LASTEXITCODE -eq 0) {
      return $candidate
    }
  }
  
  # Fallback: find any .git directory
  $result = docker exec $NAME find /app -maxdepth 2 -name ".git" -type d 2>$null | Select-Object -First 1
  if ($result) {
    return ($result -replace "/.git$", "")
  }
  
  return $null
}

function Ensure-Remote([string]$remoteUrl, [string]$repoPath) {
  # Simple: always set the remote (overwrites if exists)
  docker exec $NAME bash -c "cd '$repoPath' && git remote remove origin 2>/dev/null || true" | Out-Null
  docker exec $NAME bash -c "cd '$repoPath' && git remote add origin '$remoteUrl'" | Out-Null
}

function Ensure-Branch([string]$branch, [string]$repoPath) {
  # Simple: rename current branch to desired branch
  docker exec $NAME bash -c "cd '$repoPath' && git branch -M '$branch'" | Out-Null
}

function Commit-If-Needed([string]$message, [string]$repoPath) {
  # Simple: add all and commit with --no-verify to skip hooks/lint-staged
  docker exec $NAME bash -c "cd '$repoPath' && git add . && git commit --no-verify -m '$message' || true" | Out-Null
}

# ---------------- Main ----------------
Ensure-Docker
Ensure-Container

# 1) Inputs
Say "🔐 Enter your GitHub Personal Access Token (PAT). It will not be displayed."
$securePat = Read-Host -AsSecureString "GitHub PAT"
$patPlain  = Get-PlainTextFromSecureString $securePat
if (-not $patPlain) { Write-Host "❌ PAT cannot be empty."; exit 1 }
$patEncoded = [System.Uri]::EscapeDataString($patPlain)

$origin = Read-Host "Enter your GitHub repository origin URL (e.g., https://github.com/username/repo.git)"
if (-not $origin.StartsWith("https://github.com/")) {
  Write-Host "⚠️ Origin does not look like a GitHub https URL; continuing anyway."
}

# Insert token into origin URL: https://<token>@github.com/owner/repo.git
if ($origin -notmatch '^https://') { Write-Host "❌ Only https remotes are supported."; exit 1 }
$remoteWithPat = $origin -replace '^https://', ("https://" + $patEncoded + "@")
$masked = $origin -replace '^https://', ("https://" + (Mask-Token $patPlain) + "@")

$gitUserName = Read-Host "Enter your git user.name (e.g., yourusername)"
$gitUserEmail = Read-Host "Enter your git user.email (e.g., you@example.com)"
if (-not $gitUserName) { Write-Host "❌ user.name cannot be empty."; exit 1 }
if (-not $gitUserEmail) { Write-Host "❌ user.email cannot be empty."; exit 1 }

# Collect private key for later use in smart cache and deployment
Say "🔐 Enter your wallet private key for smart cache and deployment operations"
$securePrivateKey = Read-Host -AsSecureString "Private Key (will not be displayed)"
$userPrivateKey = Get-PlainTextFromSecureString $securePrivateKey
if (-not $userPrivateKey) { Write-Host "❌ Private key cannot be empty."; exit 1 }
if (-not $userPrivateKey.StartsWith("0x")) {
  $userPrivateKey = "0x" + $userPrivateKey
}

$branch = Select-ChallengeBranch

# 2) Find the repository path inside container
$repoPath = Find-RepoPath -branch $branch
if (-not $repoPath) {
  Write-Host "❌ No speedrun project found inside container. Looking for a directory with:"
  Write-Host "   - .git folder (git repository)"
  Write-Host "   - packages/ folder OR package.json file (project structure)"
  Write-Host "Make sure you have cloned a speedrun project properly."
  exit 1
}
# Sanitize Windows line endings to avoid bash errors
$repoPath = ($repoPath -replace "`r", "").Trim()
Say "📁 Using speedrun project: $repoPath"

# 3) Configure git identity inside container
Say "👤 Setting git identity inside container..."
docker exec $NAME bash -c "cd '$repoPath' && git config user.name '$gitUserName'" | Out-Null
docker exec $NAME bash -c "cd '$repoPath' && git config user.email '$gitUserEmail'" | Out-Null

$confirmName  = (docker exec $NAME bash -c "cd '$repoPath' && git config user.name").Trim()
$confirmEmail = (docker exec $NAME bash -c "cd '$repoPath' && git config user.email").Trim()
Write-Host "   user.name:  $confirmName"
Write-Host "   user.email: $confirmEmail"

# 4) Set remote with PAT inside container
Say "🔗 Setting remote origin (token masked): $masked"
Ensure-Remote -remoteUrl $remoteWithPat -repoPath $repoPath

# 5) Ensure correct branch inside container
Ensure-Branch -branch $branch -repoPath $repoPath

# 6) Get commit message from user and commit if needed
$commitMessage = Get-SmartInput "Enter your commit message (or press Enter to skip commit): " -allowEmpty $true
if ($commitMessage) {
  Commit-If-Needed -message $commitMessage -repoPath $repoPath
  Say "✅ Changes committed with message: '$commitMessage'"
} else {
  Say "⏭️ Skipping commit - no message provided"
}

# 7) Push from inside container
Say "🚀 Pushing to origin '$branch'..."
docker exec $NAME bash -c "cd '$repoPath' && git push -u origin '$branch'"
if ($LASTEXITCODE -eq 0) {
  Say "✅ Push complete. Your repository should be updated."
} else {
  Write-Host "❌ Push failed. Check your PAT scopes and repository permissions."
  exit 1
}

# 8) Smart Cache Configuration (Optional)
Say "🧠 Smart Cache Configuration for Gas Optimization"
$configureSmartCache = Read-Host "Are you ready for smart cache configuration for making this contract efficient for gas savings? (Y/N)"
if ($configureSmartCache -eq "Y" -or $configureSmartCache -eq "y") {
  Say "🔧 Setting up Smart Cache for gas optimization..."
  
  # Check if smart-cache-cli is already installed
  Say "🔍 Checking if smart-cache-cli is already installed..."
  docker exec $NAME bash -c "smart-cache --help" > $null 2>&1
  if ($LASTEXITCODE -eq 0) {
    Say "✅ Smart-cache-cli is already installed, skipping installation"
  } else {
    # Install smart-cache-cli globally
    Say "📦 Installing smart-cache-cli..."
    $installResult = docker exec $NAME bash -c "npm install -g smart-cache-cli" 2>&1
    if ($LASTEXITCODE -ne 0) {
      Say "⚠️ Global installation failed. Trying local installation..."
      docker exec $NAME bash -c "cd '$repoPath' && npm install smart-cache-cli" | Out-Null
      if ($LASTEXITCODE -eq 0) {
        Say "✅ Smart-cache-cli installed locally in project"
      } else {
        Write-Host "❌ Failed to install smart-cache-cli. You may need to install it manually." -ForegroundColor Red
        Write-Host "   Run: docker exec -it $NAME bash -c 'npm install -g smart-cache-cli'" -ForegroundColor Yellow
      }
    } else {
      Say "✅ Smart-cache-cli installed globally"
    }
  }
  
  # Run smart-cache init
  Say "🚀 Initializing smart cache configuration..."
  docker exec $NAME bash -c "cd '$repoPath' && npx smart-cache init" | Out-Null
  
  # Get user inputs for smart cache configuration
  Say "💡 Using the private key you provided earlier for wallet operations"
  $deployerAddress = Get-SmartInput "Enter your wallet address that deployed the contracts: "
  $contractAddress = Get-SmartInput "Enter your contract address (or press Enter to skip): " -allowEmpty $true
  
  # Update smartcache.toml with user values (robust approach)
  Say "🔧 Updating smartcache.toml with your addresses..."
  
  # Read current TOML, update values, write back
  $updateScript = @"
#!/bin/bash
set -e
cd '$repoPath'
f=smartcache.toml

# Ensure file exists
touch `$f

# Update deployed_by
if grep -q '^deployed_by' `$f; then
  sed -i "s/^deployed_by.*/deployed_by = \"`$1\"/" `$f
else
  echo "deployed_by = \"`$1\"" >> `$f
fi

# Update contract_address if provided
if [ -n "`$2" ]; then
  if grep -q '^contract_address' `$f; then
    sed -i "s/^contract_address.*/contract_address = \"`$2\"/" `$f
  else
    echo "contract_address = \"`$2\"" >> `$f
  fi
fi
"@

  # Write script to container and execute
  $scriptB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($updateScript))
  docker exec $NAME bash -c "echo '$scriptB64' | base64 -d > /tmp/update_toml.sh && chmod +x /tmp/update_toml.sh"
  docker exec $NAME bash -c "/tmp/update_toml.sh '$deployerAddress' '$contractAddress'"
  
  Say "✅ Smart cache configuration created at: $repoPath/smartcache.toml"
  
  # Smart cache configuration retry loop
  $maxRetries = 3
  $retryCount = 0
  $smartCacheAddSuccess = $false
  
  do {
    $retryCount++
    if ($retryCount -gt 1) {
      Say "🔄 Retry attempt $retryCount of $maxRetries"
    }
    
    # Run smart-cache add command
    Say "🚀 Running smart-cache add command..."
    $addCmd = "cd '$repoPath' && npx -y smart-cache add"
    if ($contractAddress) { $addCmd = "cd '$repoPath' && npx -y smart-cache add $contractAddress" }
    $smartCacheAddOutput = docker exec $NAME bash -c $addCmd 2>&1
    $smartCacheAddSuccess = ($LASTEXITCODE -eq 0)
    
    # Display the output to user
    Write-Host "📋 Smart-cache add command output:" -ForegroundColor Cyan
    Write-Host $smartCacheAddOutput
    
    if ($smartCacheAddSuccess) {
      Say "✅ Smart-cache add command executed successfully!"
      break
    } else {
      Say "⚠️ Smart-cache add command encountered errors"
      Write-Host "Error code: $LASTEXITCODE" -ForegroundColor Yellow
      
      if ($retryCount -lt $maxRetries) {
        $retry = Read-Host "Would you like to retry with new contract address and deployer address? (Y/N)"
        if ($retry -eq "Y" -or $retry -eq "y") {
          # Get new user inputs for smart cache configuration
          $deployerAddress = Get-SmartInput "Enter your wallet address that deployed the contracts: "
          $contractAddress = Get-SmartInput "Enter your contract address (or press Enter to skip): " -allowEmpty $true
          
                     # Update smartcache.toml with new inputs
           Say "🔧 Updating smartcache.toml with new addresses..."
           docker exec $NAME bash -c "/tmp/update_toml.sh '$deployerAddress' '$contractAddress'"
          
          Say "✅ Smart cache configuration updated with new addresses"
        } else {
          break
        }
      } else {
        Say "⚠️ Maximum retry attempts reached ($maxRetries)"
        break
      }
    }
  } while ($retryCount -lt $maxRetries -and -not $smartCacheAddSuccess)
  
  # Commit and push smart cache configuration
  $smartCacheCommitMsg = Get-SmartInput "Enter commit message for smart cache configuration (or press Enter to skip): " -allowEmpty $true
  if ($smartCacheCommitMsg) {
    docker exec $NAME bash -c "cd '$repoPath' && git add smartcache.toml && git commit --no-verify -m '$smartCacheCommitMsg'" | Out-Null
    Say "✅ Smart cache configuration committed"
    
    # Check if smart-cache add was successful before pushing
    if (-not $smartCacheAddSuccess) {
      Say "⚠️ Smart-cache add command had errors after $retryCount attempts"
      $continuePush = Read-Host "Are you sure to push the code to GitHub without successful run of smart-cache add command? (Y/N)"
      if ($continuePush -ne "Y" -and $continuePush -ne "y") {
        Say "⏭️ Skipping push. You can run smart-cache add manually and push later."
        return
      }
    }
    
    # Push the new changes
    Say "🚀 Pushing smart cache configuration to GitHub..."
    docker exec $NAME bash -c "cd '$repoPath' && git push origin '$branch'"
    if ($LASTEXITCODE -eq 0) {
      Say "✅ Smart cache configuration pushed to GitHub successfully!"
    } else {
      Write-Host "❌ Failed to push smart cache configuration. You can push manually later."
    }
  } else {
    Say "⏭️ Smart cache configuration created but not committed. You can commit manually later."
  }
} else {
  Say "⏭️ Skipping smart cache configuration. You can configure it manually later if needed."
}

# 9) Rust Crate Automation (Optional)
Say "🦀 Rust Crate Automation for Contract Optimization"
$configureRustCrate = Read-Host "Are you ready to use RUST crate to automate the process? (Y/N)"
if ($configureRustCrate -eq "Y" -or $configureRustCrate -eq "y") {
  Say "🔧 Setting up Rust crate automation..."
  
  # Find Cargo.toml directory
  Say "📁 Locating Cargo.toml directory..."
  $cargoDir = docker exec $NAME bash -c "find '$repoPath' -name 'Cargo.toml' -type f | head -1 | xargs dirname" 2>$null
  if (-not $cargoDir) {
    $cargoDir = docker exec $NAME bash -c "find '$repoPath' -name 'rust-toolchain.toml' -type f | head -1 | xargs dirname" 2>$null
  }
  
  if (-not $cargoDir) {
    Write-Host "❌ Could not find Cargo.toml or rust-toolchain.toml directory" -ForegroundColor Red
    Say "⏭️ Skipping Rust crate automation"
  } else {
    $cargoDir = ($cargoDir -replace "`r", "").Trim()
    Say "✅ Found Rust project at: $cargoDir"
    
    # Install stylus-cache-sdk
    Say "📦 Installing stylus-cache-sdk..."
    docker exec $NAME bash -c "cd '$cargoDir' && cargo add stylus-cache-sdk" | Out-Null
    if ($LASTEXITCODE -eq 0) {
      Say "✅ stylus-cache-sdk installed successfully"
    } else {
      Write-Host "❌ Failed to install stylus-cache-sdk" -ForegroundColor Red
      Say "⏭️ Skipping Rust crate automation"
      return
    }
    
    # Find and update lib.rs
    Say "🔧 Updating lib.rs file..."
    $libRsPath = docker exec $NAME bash -c "find '$cargoDir' -name 'lib.rs' -type f | head -1" 2>$null
    if (-not $libRsPath) {
      Write-Host "❌ Could not find lib.rs file" -ForegroundColor Red
      Say "⏭️ Skipping lib.rs updates"
    } else {
      $libRsPath = ($libRsPath -replace "`r", "").Trim()
      Say "✅ Found lib.rs at: $libRsPath"
      
      # Update lib.rs with import and cacheable function
      $updateLibScript = @"
#!/bin/bash
set -e
libfile='$libRsPath'

# Add import if not already present
if ! grep -q "use stylus_cache_sdk" "`$libfile"; then
  # Find the first line that starts with 'use' and add our import before it
  if grep -q "^use " "`$libfile"; then
    sed -i '1i use stylus_cache_sdk::{is_contract_cacheable};' "`$libfile"
  else
    # If no use statements, add at the top after any comments
    sed -i '1i use stylus_cache_sdk::{is_contract_cacheable};\n' "`$libfile"
  fi
fi

# Add is_cacheable function if not already present
if ! grep -q "pub fn is_cacheable" "`$libfile"; then
  # Find impl block and add the function
  if grep -q "impl " "`$libfile"; then
    # Add the function before the last closing brace of the impl block
    sed -i '/impl /,/^}/ {
      /^}/ i\    #[public]\
    pub fn is_cacheable(&self) -> bool {\
        is_contract_cacheable()\
    }\

    }' "`$libfile"
  fi
fi
"@
      
      $libScriptB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($updateLibScript))
      docker exec $NAME bash -c "echo '$libScriptB64' | base64 -d > /tmp/update_lib.sh && chmod +x /tmp/update_lib.sh"
      docker exec $NAME bash -c "/tmp/update_lib.sh"
      
      Say "✅ lib.rs updated with stylus-cache-sdk integration"
      
      # Ask user to make contract unique
      Say "🎯 Make Your Contract Unique"
      Write-Host "To make your contract unique, you should rename one of your functions."
      Write-Host "For example: 'set_number' → 'set_number_yourname'"
      Write-Host ""
      $makeUnique = Read-Host "Would you like to make manual changes to make your contract unique? (Y/N)"
      if ($makeUnique -eq "Y" -or $makeUnique -eq "y") {
        Write-Host "✅ Please manually edit your lib.rs file to rename a function and make it unique."
        Write-Host "📝 The file is located at: $libRsPath"
        Write-Host "⏸️  Press Enter when you're done making changes..."
        Read-Host
      }
      
      # Ensure WebAssembly target is installed
      Say "🔧 Ensuring WebAssembly target is installed..."
      docker exec $NAME bash -c "rustup target add wasm32-unknown-unknown" | Out-Null
      if ($LASTEXITCODE -eq 0) {
        Say "✅ WebAssembly target ready"
      } else {
        Write-Host "⚠️ Warning: Could not install wasm32-unknown-unknown target" -ForegroundColor Yellow
      }
      
      # Deploy contract with cargo stylus
      Say "🚀 Deploying contract with cargo stylus..."
      Write-Host "Running: cargo stylus deploy --endpoint='https://sepolia-rollup.arbitrum.io/rpc' --private-key=<your-key> --no-verify"
      
      # Use the private key collected at the beginning of the script
      $deployOutput = docker exec $NAME bash -c "cd '$cargoDir' && cargo stylus deploy --endpoint='https://sepolia-rollup.arbitrum.io/rpc' --private-key='$userPrivateKey' --no-verify" 2>&1
      $deploySuccess = ($LASTEXITCODE -eq 0)
      
      # Display deploy output
      Write-Host "📋 Cargo stylus deploy output:" -ForegroundColor Cyan
      Write-Host $deployOutput
      
      if ($deploySuccess) {
        # Extract contract address from deployment output
        $contractAddressMatch = $deployOutput | Select-String -Pattern "deployed code at address (0x[0-9a-fA-F]{40})" -AllMatches
        if (-not $contractAddressMatch) {
          # Try alternative patterns that might be in the output
          $contractAddressMatch = $deployOutput | Select-String -Pattern "(0x[0-9a-fA-F]{40})" -AllMatches | Select-Object -Last 1
        }
        
        if ($contractAddressMatch) {
          $deployedContractAddress = $contractAddressMatch.Matches[0].Groups[1].Value
          if (-not $deployedContractAddress) {
            $deployedContractAddress = $contractAddressMatch.Matches[0].Value
          }
          Say "✅ Contract deployed successfully!"
          Write-Host "🎯 Contract Address: $deployedContractAddress" -ForegroundColor Green
          Write-Host "📋 Save this address - you'll need it for interacting with your contract!" -ForegroundColor Yellow
        } else {
          Say "✅ Contract deployed successfully!"
          Write-Host "⚠️ Could not extract contract address from output. Check the deployment log above." -ForegroundColor Yellow
        }
      } else {
        Say "⚠️ Contract deployment encountered errors"
        Write-Host "Error code: $LASTEXITCODE" -ForegroundColor Yellow
        $continuePushAfterDeploy = Read-Host "Do you want to push the code to GitHub despite deployment errors? (Y/N)"
        if ($continuePushAfterDeploy -ne "Y" -and $continuePushAfterDeploy -ne "y") {
          Say "⏭️ Skipping push due to deployment errors. You can deploy and push manually later."
          return
        }
      }
      
      # Commit and push Rust changes
      $rustCommitMsg = Get-SmartInput "Enter commit message for Rust crate automation (or press Enter to skip): " -allowEmpty $true
      if ($rustCommitMsg) {
        docker exec $NAME bash -c "cd '$repoPath' && git add . && git commit --no-verify -m '$rustCommitMsg'" | Out-Null
        Say "✅ Rust changes committed"
        
        # Push the Rust changes
        Say "🚀 Pushing Rust crate automation to GitHub..."
        docker exec $NAME bash -c "cd '$repoPath' && git push origin '$branch'"
        if ($LASTEXITCODE -eq 0) {
          Say "✅ Rust crate automation pushed to GitHub successfully!"
          Say "🎉 All automation complete! Your contract now includes:"
          Write-Host "   ✅ Smart cache configuration"
          Write-Host "   ✅ Stylus cache SDK integration"
          Write-Host "   ✅ Optimized contract functions"
        } else {
          Write-Host "❌ Failed to push Rust changes. You can push manually later." -ForegroundColor Red
        }
      } else {
        Say "⏭️ Rust changes created but not committed. You can commit manually later."
      }
    }
  }
} else {
  Say "⏭️ Skipping Rust crate automation. You can configure it manually later if needed."
}