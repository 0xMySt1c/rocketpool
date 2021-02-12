pragma solidity 0.7.6;

// SPDX-License-Identifier: GPL-3.0-only

import "../../RocketBase.sol";
import "../../../interface/RocketVaultInterface.sol";
import "../../../interface/dao/node/RocketDAONodeTrustedInterface.sol";
import "../../../interface/dao/node/RocketDAONodeTrustedActionsInterface.sol";
import "../../../interface/dao/node/settings/RocketDAONodeTrustedSettingsMembersInterface.sol";
import "../../../interface/dao/node/settings/RocketDAONodeTrustedSettingsProposalsInterface.sol";
import "../../../interface/rewards/claims/RocketClaimTrustedNodeInterface.sol";
import "../../../interface/util/AddressSetStorageInterface.sol";

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";


// The Trusted Node DAO Actions
contract RocketDAONodeTrustedActions is RocketBase, RocketDAONodeTrustedActionsInterface { 

    using SafeMath for uint;

    // Events
    event ActionJoined(address indexed _nodeAddress, uint256 _rplBondAmount, uint256 time);  
    event ActionLeave(address indexed _nodeAddress, uint256 _rplBondAmount, uint256 time);
    event ActionReplace(address indexed _currentNodeAddress, address indexed _newNodeAddress, uint256 time);
    event ActionKick(address indexed _nodeAddress, uint256 _rplBondAmount, uint256 time);

    // Calculate using this as the base
    uint256 private calcBase = 1 ether;

    // The namespace for any data stored in the trusted node DAO (do not change)
    string private daoNameSpace = 'dao.trustednodes';


    // Construct
    constructor(address _rocketStorageAddress) RocketBase(_rocketStorageAddress) {
        // Version
        version = 1;
    }

    /*** Internal Methods **********************/

    // Add a new member to the DAO
    function _memberAdd(address _nodeAddress, uint256 _rplBondAmountPaid) private onlyRegisteredNode(_nodeAddress) {
        // Load contracts
        RocketClaimTrustedNodeInterface rocketClaimTrustedNode = RocketClaimTrustedNodeInterface(getContractAddress("rocketClaimTrustedNode"));
        RocketDAONodeTrustedInterface rocketDAONode = RocketDAONodeTrustedInterface(getContractAddress("rocketDAONodeTrusted"));
        AddressSetStorageInterface addressSetStorage = AddressSetStorageInterface(getContractAddress("addressSetStorage"));
        // Check current node status
        require(rocketDAONode.getMemberIsValid(_nodeAddress) != true, "This node is already part of the trusted node DAO");
        // Flag them as a member now that they have accepted the invitation and record the size of the bond they paid
        setBool(keccak256(abi.encodePacked(daoNameSpace, "member", _nodeAddress)), true);
        // Add the bond amount they have paid
        if(_rplBondAmountPaid > 0) setUint(keccak256(abi.encodePacked(daoNameSpace, "member.bond.rpl", _nodeAddress)), _rplBondAmountPaid);
        // Record the block number they joined at
        setUint(keccak256(abi.encodePacked(daoNameSpace, "member.joined.block", _nodeAddress)), block.number);
         // Add to member index now
        addressSetStorage.addItem(keccak256(abi.encodePacked(daoNameSpace, "member.index")), _nodeAddress); 
        // Register for them to receive rewards now
        rocketClaimTrustedNode.register(_nodeAddress, true);
    }

    // Remove a member from the DAO
    function _memberRemove(address _nodeAddress) private onlyTrustedNode(_nodeAddress) {
        // Load contracts
        RocketClaimTrustedNodeInterface rocketClaimTrustedNode = RocketClaimTrustedNodeInterface(getContractAddress("rocketClaimTrustedNode"));
        AddressSetStorageInterface addressSetStorage = AddressSetStorageInterface(getContractAddress("addressSetStorage"));
        // Deregister them from receiving rewards now
        rocketClaimTrustedNode.register(_nodeAddress, false);
        // Remove their membership now
        deleteBool(keccak256(abi.encodePacked(daoNameSpace, "member", _nodeAddress)));
        deleteAddress(keccak256(abi.encodePacked(daoNameSpace, "member.address", _nodeAddress)));
        deleteString(keccak256(abi.encodePacked(daoNameSpace, "member.id", _nodeAddress)));
        deleteString(keccak256(abi.encodePacked(daoNameSpace, "member.email", _nodeAddress)));
        deleteUint(keccak256(abi.encodePacked(daoNameSpace, "member.bond.rpl", _nodeAddress)));
        deleteUint(keccak256(abi.encodePacked(daoNameSpace, "member.joined.block", _nodeAddress)));
         // Remove from member index now
        addressSetStorage.removeItem(keccak256(abi.encodePacked(daoNameSpace, "member.index")), _nodeAddress); 
    }
  
    /*** Action Methods ************************/

    // When a new member has been successfully invited to join, they must call this method to join officially
    // They will be required to have the RPL bond amount in their account
    function actionJoin() override external onlyRegisteredNode(msg.sender) onlyLatestContract("rocketDAONodeTrustedActions", address(this)) {
        // Set some intiial contract address
        address rocketVaultAddress = getContractAddress('rocketVault');
        address rocketTokenRPLAddress = getContractAddress('rocketTokenRPL');
        // Load contracts
        IERC20 rplInflationContract = IERC20(rocketTokenRPLAddress);
        RocketVaultInterface rocketVault = RocketVaultInterface(rocketVaultAddress);
        RocketDAONodeTrustedInterface rocketDAONode = RocketDAONodeTrustedInterface(getContractAddress("rocketDAONodeTrusted"));
        RocketDAONodeTrustedSettingsMembersInterface rocketDAONodeTrustedSettingsMembers = RocketDAONodeTrustedSettingsMembersInterface(getContractAddress("rocketDAONodeTrustedSettingsMembers"));
        RocketDAONodeTrustedSettingsProposalsInterface rocketDAONodeTrustedSettingsProposals = RocketDAONodeTrustedSettingsProposalsInterface(getContractAddress("rocketDAONodeTrustedSettingsProposals"));
        // The block that the member was successfully invited to join the DAO
        uint256 memberInvitedBlock = rocketDAONode.getMemberProposalExecutedBlock('invited', msg.sender);
        // The current member bond amount in RPL that's required
        uint256 rplBondAmount = rocketDAONodeTrustedSettingsMembers.getRPLBond();
        // Has their invite expired?
        require(memberInvitedBlock.add(rocketDAONodeTrustedSettingsProposals.getActionBlocks()) > block.number, "This nodes invitation to join has expired, please apply again");
        // Verify they have allowed this contract to spend their RPL for the bond
        require(rplInflationContract.allowance(msg.sender, address(this)) >= rplBondAmount, "Not enough allowance given to RocketDAONodeTrusted contract for transfer of RPL bond tokens");
        // Transfer the tokens to this contract now
        require(rplInflationContract.transferFrom(msg.sender, address(this), rplBondAmount), "Token transfer to RocketDAONodeTrusted contract was not successful");
        // Allow RocketVault to transfer these tokens to itself now
        require(rplInflationContract.approve(rocketVaultAddress, rplBondAmount), "Approval for RocketVault to spend RocketDAONodeTrusted RPL bond tokens was not successful");
        // Let vault know it can move these tokens to itself now and credit the balance to this contract
        require(rocketVault.depositToken(getContractName(address(this)), rocketTokenRPLAddress, rplBondAmount), "Rocket Vault RPL bond deposit deposit was not successful");
        // Add them as a member now that they have accepted the invitation and record the size of the bond they paid
        _memberAdd(msg.sender, rplBondAmount);
        // Log it
        emit ActionJoined(msg.sender, rplBondAmount, block.timestamp);
    }
    

    // When a new member has successfully requested to leave with a proposal, they must call this method to leave officially and receive their RPL bond
    function actionLeave(address _rplBondRefundAddress) override external onlyTrustedNode(msg.sender) onlyLatestContract("rocketDAONodeTrustedActions", address(this)) {
        // Load contracts
        RocketVaultInterface rocketVault = RocketVaultInterface(getContractAddress('rocketVault'));
        RocketDAONodeTrustedInterface rocketDAONode = RocketDAONodeTrustedInterface(getContractAddress("rocketDAONodeTrusted"));
        RocketDAONodeTrustedSettingsProposalsInterface rocketDAONodeTrustedSettingsProposals = RocketDAONodeTrustedSettingsProposalsInterface(getContractAddress("rocketDAONodeTrustedSettingsProposals"));
        // Check this wouldn't dip below the min required trusted nodes
        require(rocketDAONode.getMemberCount() > rocketDAONode.getMemberMinRequired(), "Member count will fall below min required, this member must choose to be replaced");
        // Get the block that they were approved to leave at
        uint256 leaveAcceptedBlock = rocketDAONode.getMemberProposalExecutedBlock('leave', msg.sender);
        // Has their leave request expired?
        require(leaveAcceptedBlock.add(rocketDAONodeTrustedSettingsProposals.getActionBlocks()) > block.number, "This member has not been approved to leave or request has expired, please apply to leave again");
        // They were succesful, lets refund their RPL Bond
        uint256 rplBondRefundAmount = rocketDAONode.getMemberRPLBondAmount(msg.sender);
        // Refund
        if(rplBondRefundAmount > 0) {
            // Valid withdrawal address
            require(_rplBondRefundAddress != address(0x0), "Member has not supplied a valid address for their RPL bond refund");
            // Send tokens now
            require(rocketVault.withdrawToken(_rplBondRefundAddress, getContractAddress('rocketTokenRPL'), rplBondRefundAmount), "Could not send RPL bond token balance from vault");
        }
        // Remove them now
        _memberRemove(msg.sender);
        // Log it
        emit ActionLeave(msg.sender, rplBondRefundAmount, block.timestamp);
    }


    // A member can choose to have their spot in the DAO replaced by another member 
    // Must be run by the current member node that wishes to be replaced (so it's verified they want out)
    function actionReplace() override external onlyTrustedNode(msg.sender) onlyLatestContract("rocketDAONodeTrustedActions", address(this)) {
        // Load contracts
        RocketDAONodeTrustedInterface rocketDAONode = RocketDAONodeTrustedInterface(getContractAddress("rocketDAONodeTrusted"));
        RocketDAONodeTrustedSettingsProposalsInterface rocketDAONodeTrustedSettingsProposals = RocketDAONodeTrustedSettingsProposalsInterface(getContractAddress("rocketDAONodeTrustedSettingsProposals"));
        // Get the current member that wishes to be replaced
        address memberCurrent = rocketDAONode.getMemberReplacedAddress('current', msg.sender);
        // Get the replacement member 
        address memberReplacement = rocketDAONode.getMemberReplacedAddress('new', msg.sender);
        // Verify the replacement member is still a registered node
        require(getBool(keccak256(abi.encodePacked("node.exists", memberReplacement))), "Replacement member is no longer a registered RP node");
        // Check they are confirming they wish to be replaced
        require(memberCurrent == msg.sender, "The replace method must be run by the current member that wishes to be replaced");
        // The block that the member was successfully allowed to be replaced
        uint256 memberReplaceBlock = rocketDAONode.getMemberProposalExecutedBlock('replace', msg.sender);
        // Has their invite expired?
        require(memberReplaceBlock.add(rocketDAONodeTrustedSettingsProposals.getActionBlocks()) > block.number, "This nodes invitation to replace a node has expired, please apply again");
        // Add new member now (rpl bond transfers to the new member)
        _memberAdd(memberReplacement, rocketDAONode.getMemberRPLBondAmount(memberCurrent));
        // Remove existing member now
        _memberRemove(memberCurrent);
        // Log it
        emit ActionReplace(memberCurrent, msg.sender, block.timestamp);
    }


    // A member can be evicted from the DAO by proposal, send their remaining RPL balance to them and remove from the DAO
    // Is run via the main DAO contract when the proposal passes and is executed
    function actionKick(address _nodeAddress) override external onlyTrustedNode(_nodeAddress) onlyLatestContract("rocketDAONodeTrustedProposals", msg.sender) {
        // Load contracts
        RocketVaultInterface rocketVault = RocketVaultInterface(getContractAddress('rocketVault'));
        RocketDAONodeTrustedInterface rocketDAONode = RocketDAONodeTrustedInterface(getContractAddress("rocketDAONodeTrusted"));
        // Get the
        uint256 rplBondRefundAmount = rocketDAONode.getMemberRPLBondAmount(_nodeAddress);
        // Refund
        if(rplBondRefundAmount > 0) {
            // Send tokens now
            require(rocketVault.withdrawToken(_nodeAddress, getContractAddress('rocketTokenRPL'), rplBondRefundAmount), "Could not send kicked members RPL bond token balance from vault");
        }
        // Remove the member now
        _memberRemove(_nodeAddress);
        // Log it
        emit ActionKick(_nodeAddress, rplBondRefundAmount, block.timestamp);   
    }


}
