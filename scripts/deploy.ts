import { ethers } from 'hardhat'

async function main() {

  const [deployer] = await ethers.getSigners()

  console.log('Deploying contracts with the account: ', deployer.address)

  console.log('Account balance: ', (await deployer.provider.getBalance(deployer.address)).toString())

  const dFinexFactory = await ethers.getContractFactory('DFinex')
  const dFinex = await dFinexFactory.deploy()

  console.log('DFinex deployed to:', (await dFinex.getAddress()))
}

main().catch((error) => {
  console.error(error)
  process.exitCode = 1
})