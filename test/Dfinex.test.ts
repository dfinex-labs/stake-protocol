import { ethers } from 'hardhat'
import type { Signer } from 'ethers'
import chai from 'chai'
import chaiAsPromised from 'chai-as-promised'

import { DFinex } from './../typechain-types/DFinex'
import { DFinex__factory } from './../typechain-types/factories/DFinex__factory'

chai.use(chaiAsPromised)

const { expect } = chai

describe('DFinex', () => {
  let dFinexFactory: DFinex__factory
  let dFinex: DFinex

  describe('Deployment', () => {

    beforeEach(async () => {

      dFinexFactory = new DFinex__factory()

      dFinex = await dFinexFactory.deploy()

      await dFinex.deployed()
      
    })

    it('should have the correct address', async () => {
      expect(dFinex.address)
    })
  })
})