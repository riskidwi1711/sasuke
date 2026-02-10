.PHONY: help generate up down restart clean deploycc test gateway-start gateway-dev purge-wallet

help: ## Show this help
	@echo "Available commands:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

generate: ## Generate crypto material and genesis block
	@echo "Generating crypto material and genesis block..."
	@./scripts/network.sh generate

up: ## Start the network with all components
	@echo "Starting Fabric network with CA, IPFS, and Explorer..."
	@./scripts/network.sh up -ca -ipfs -explorer

up-no-explorer: ## Start network without Explorer (for setup ordering)
	@echo "Starting Fabric network with CA and IPFS..."
	@./scripts/network.sh up -ca -ipfs

up-explorer: ## Start Explorer separately (peers must be ready)
	@echo "Starting Hyperledger Explorer..."
	@docker compose --env-file .env -f docker/docker-compose-explorer.yaml up -d

up-basic: ## Start only Fabric network
	@echo "Starting Fabric network..."
	@./scripts/network.sh up

down: ## Stop and clean the network
	@echo "Stopping network and cleaning up..."
	@./scripts/network.sh down

restart: ## Restart the network
	@echo "Restarting network..."
	@./scripts/network.sh restart -ca -ipfs -explorer

createchannel: ## Create channel
	@echo "Creating channel..."
	@./scripts/network.sh createChannel

joinchannel: ## Join peers to channel
	@echo "Joining peers to channel..."
	@./scripts/network.sh joinChannel

deploycc: ## Deploy chaincode (use: make deploycc CC_NAME=general)
	@echo "Deploying chaincode..."
	@./scripts/network.sh deployCC -ccn $(or $(CC_NAME),general) -ccv $(or $(CC_VERSION),1.0) -ccp $(or $(CC_PATH),./chaincode/general) -ccl $(or $(CC_LANG),golang)

deploycc_combined: ## Deploy combined v2 chaincode (default CC_NAME=chaincode_v2)
	@echo "Deploying combined v2 chaincode..."
	@./scripts/network.sh deployCC -ccn $(or $(CC_NAME),chaincode_v2) -ccv $(or $(CC_VERSION),1.0) -ccp $(or $(CC_PATH),./chaincode/v2) -ccl $(or $(CC_LANG),golang)

upgradecc: ## Upgrade chaincode (override CC_VERSION/CC_SEQUENCE)
	@echo "Upgrading chaincode to version 2.0..."
	@CC_SEQUENCE=$(or $(CC_SEQUENCE),2) ./scripts/network.sh deployCC -ccn $(or $(CC_NAME),asset-contract) -ccv $(or $(CC_VERSION),2.0) -ccp $(or $(CC_PATH),./chaincode/asset-contract) -ccl $(or $(CC_LANG),golang)

upgradecc_combined: ## Upgrade combined v2 chaincode (override CC_VERSION/CC_SEQUENCE)
	@echo "Upgrading combined v2 chaincode..."
	@CC_SEQUENCE=$(or $(CC_SEQUENCE),2) ./scripts/network.sh deployCC -ccn $(or $(CC_NAME),chaincode_v2) -ccv $(or $(CC_VERSION),2.0) -ccp $(or $(CC_PATH),./chaincode/v2) -ccl $(or $(CC_LANG),golang)

test: ## Run chaincode tests (Go)
	@echo "Testing chaincode (Go)..."
	@cd chaincode/asset-contract && if [ -f go.mod ]; then go test ./... || true; else echo "No Go tests found"; fi

install-deps: ## Install chaincode dependencies (Go)
	@echo "Installing chaincode dependencies (Go modules)..."
	@export PATH=$$PATH:/usr/local/go/bin && cd chaincode/asset-contract && if [ -f go.mod ]; then (go mod download || true); else echo "No Go modules to install"; fi

status: ## Show network status
	@echo "Network Status:"
	@docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

logs-peer0-org1: ## Show logs for Org1 Peer0
	@docker logs -f peer0.org1.example.com

logs-orderer: ## Show logs for Orderer
	@docker logs -f orderer.example.com

logs-ipfs: ## Show logs for IPFS
	@docker logs -f ipfs-node

logs-explorer: ## Show logs for Explorer
	@docker logs -f explorer

clean: ## Clean all generated files and containers
	@echo "Cleaning all generated files..."
	@./scripts/network.sh down
	@docker run --rm -v $(PWD):/work alpine sh -c "rm -rf /work/organizations /work/channel-artifacts"
	@rm -f *.tar.gz log.txt

backup: ## Backup crypto material and chaincode
	@echo "Creating backup..."
	@tar -czf backup-$(shell date +%Y%m%d-%H%M%S).tar.gz organizations/ chaincode/ config/
	@echo "Backup created: backup-$(shell date +%Y%m%d-%H%M%S).tar.gz"

setup: ## Complete setup (generate, up, channel, deploycc)
	@echo "Running complete setup..."
	@make generate
	@make up-no-explorer
	@echo "Waiting for peers to be ready..."
	@sleep 10
	@make createchannel
	@sleep 3
	@make joinchannel
	@sleep 3
	@make install-deps
	@make deploycc CC_NAME=asset-contract CC_PATH=./chaincode/asset-contract
	@echo "Starting Explorer (peers are now ready)..."
	@make up-explorer
	@sleep 5
	@echo "Setup completed!"

addorg3: ## Incrementally add Org3 (no reset): crypto, peer up, channel update, join, install CC
	@echo "Adding Org3 incrementally..."
	@bash scripts/add_org3.sh

# --- Gateway helpers ---
gateway-start: ## Start gateway API server
	@echo "Starting gateway API..."
	@npm --prefix gateway run api

gateway-dev: ## Start gateway in dev (nodemon)
	@echo "Starting gateway (dev)..."
	@npm --prefix gateway run dev

purge-wallet: ## Purge gateway wallet identities (use: make purge-wallet MSP=Org1MSP | ALL=true)
	@echo "Purging gateway wallet identities..."
	@if [ "$(ALL)" = "true" ]; then \
		npm --prefix gateway run purge:wallet -- --all; \
	else \
		if [ -z "$(MSP)" ]; then echo "Set MSP=<MSP> or ALL=true" && exit 2; fi; \
		npm --prefix gateway run purge:wallet -- --msp $(MSP); \
	fi
