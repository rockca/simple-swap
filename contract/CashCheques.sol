// SPDX-License-Identifier: BSD-3-Clause
pragma solidity =0.7.6;
pragma abicoder v2;
//import "./SimpleSwapFactory.sol";
//import "./SimpleSwap.sol";


interface ChequeInterface { 
    function cashChequeFromBatch(
    address beneficiary,
    address recipient,
    uint cumulativePayout,
    bytes memory beneficiarySig,
    bytes memory issuerSig
  ) external;
}

interface ChequeFactory {
    function deployedContracts(address chequebook) view external returns(bool);
}


contract CachCheques {
    
    ChequeFactory public factory;
    ChequeInterface _simpleSwap;
    
    constructor(address _factory) public {
        factory = ChequeFactory(_factory);
    }
    
    
    function batchCashcheques(
        address recipient, 
        address[] memory beneficiarys, 
        address[] memory chequebooks, 
        uint[] memory amounts, 
        bytes[] memory beneficiarySigs,
        bytes[] memory cheques
    ) public {
        uint len_chequebook = chequebooks.length;
        
        require(len_chequebook == amounts.length 
            && len_chequebook == cheques.length 
            && len_chequebook == beneficiarys.length 
            && len_chequebook == beneficiarySigs.length 
            && len_chequebook > 0);
        
        for (uint index = 0; index < len_chequebook; index++) {
            require(factory.deployedContracts(chequebooks[index]));
            _simpleSwap = ChequeInterface(chequebooks[index]);
            _simpleSwap.cashChequeFromBatch(beneficiarys[index], recipient, amounts[index], beneficiarySigs[index], cheques[index]);
        }
    }
}
