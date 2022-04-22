//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;
import {IEvaFlowController} from "./interfaces/IEvaFlowController.sol";
import {IEvaSafesFactory} from "./interfaces/IEvaSafesFactory.sol";
import {FlowStatus, KeepNetWork, EvabaseHelper} from "./lib/EvabaseHelper.sol";
import {Utils} from "./lib/Utils.sol";
import {TransferHelper} from "./lib/TransferHelper.sol";
import {IEvaSafes} from "./interfaces/IEvaSafes.sol";
import {IEvaFlow} from "./interfaces/IEvaFlow.sol";
import {IEvabaseConfig} from "./interfaces/IEvabaseConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract EvaFlowController is IEvaFlowController, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    EvaFlowMeta[] public flowMetas;
    MinConfig public minConfig;
    mapping(address => EvaUserMeta) public userMetaMap;
    // bytes4 private constant FUNC_SELECTOR = bytes4(keccak256("execute(bytes)"));

    ////need exec flows
    using EvabaseHelper for EvabaseHelper.UintSet;
    mapping(KeepNetWork => EvabaseHelper.UintSet) vaildFlows;
    // EvabaseHelper.UintSet vaildFlows;
    uint256 private constant REGISTRY_GAS_OVERHEAD = 80_000;
    // using LibSingleList for LibSingleList.List;
    // using LibSingleList for LibSingleList.Iterate;
    // LibSingleList.List vaildFlows;

    uint256 public constant MAX_INT = 2 ^ (256 - 1);

    //可提取的手续费
    uint256 public paymentEthAmount;
    uint256 public paymentGasAmount;

    IEvaSafesFactory public evaSafesFactory;

    IEvabaseConfig public config;

    constructor(address _config, address _evaSafesFactory) {
        require(_evaSafesFactory != address(0), "addess is 0x");
        require(_config != address(0), "addess is 0x");
        evaSafesFactory = IEvaSafesFactory(_evaSafesFactory);
        config = IEvabaseConfig(_config);
        flowMetas.push(
            EvaFlowMeta({
                flowStatus: FlowStatus.Unknown,
                keepNetWork: KeepNetWork.ChainLink,
                maxVaildBlockNumber: MAX_INT,
                admin: msg.sender,
                lastKeeper: address(0),
                lastExecNumber: block.number,
                lastVersionflow: address(0),
                flowName: "init",
                checkData: ""
            })
        );
    }

    function setMinConfig(MinConfig memory _minConfig) external onlyOwner {
        minConfig = _minConfig;
        emit SetMinConfig(
            msg.sender,
            _minConfig.feeRecived,
            _minConfig.feeToken,
            _minConfig.minGasFundForUser,
            _minConfig.minGasFundOneFlow,
            _minConfig.PPB,
            _minConfig.blockCountPerTurn
        );
    }

    function checkEnoughGas() internal view {
        bool isEnoughGas = true;
        unchecked {
            if (minConfig.feeToken == address(0)) {
                isEnoughGas =
                    (msg.value + userMetaMap[msg.sender].ethBal >=
                        minConfig.minGasFundForUser) &&
                    (msg.value + userMetaMap[msg.sender].ethBal >=
                        (userMetaMap[msg.sender].vaildFlowsNum + 1) *
                            minConfig.minGasFundOneFlow);
            } else {
                isEnoughGas =
                    (userMetaMap[msg.sender].gasTokenBal >=
                        minConfig.minGasFundForUser) &&
                    (userMetaMap[msg.sender].gasTokenBal >=
                        (userMetaMap[msg.sender].vaildFlowsNum + 1) *
                            minConfig.minGasFundOneFlow);
            }
        }

        require(isEnoughGas, "gas balance is not enough");
    }

    function _beforeCreateFlow(
        string memory _flowName,
        KeepNetWork _keepNetWork,
        bytes memory _input
    ) internal {
        //check size
        require(_input.length > 0, "flowCode can't null");
        //check SafeWallet
        require(
            evaSafesFactory.get(msg.sender) != address(0),
            "safe wallet is 0x"
        );

        require(bytes(_flowName).length > 0, "flowName is empty");

        require(
            uint256(_keepNetWork) >= uint256(KeepNetWork.ChainLink),
            "Illegal keepNetWork >"
        );

        require(
            uint256(_keepNetWork) <= uint256(KeepNetWork.Others),
            "Illegal keepNetWork <"
        );
    }

    function createFlow(
        string memory _flowName,
        KeepNetWork _keepNetWork,
        address _flowAddress,
        bytes memory _flowCode,
        uint256 gasFee
    )
        external
        payable
        override
        nonReentrant
        returns (uint256 flowid, address add)
    {
        _beforeCreateFlow(_flowName, _keepNetWork, _flowCode);

        checkEnoughGas();
        require(gasFee <= msg.value, "gasFee < value");
        uint256 _value = msg.value - gasFee;
        bytes memory _checkdata;
        // uint256 gasFee = msg.value;
        // address addr;
        if (_flowAddress == address(0)) {
            //create
            uint256 size;
            assembly {
                _flowAddress := create(
                    0,
                    add(_flowCode, 0x20),
                    mload(_flowCode)
                )
                size := extcodesize(_flowAddress)
                if iszero(extcodesize(_flowAddress)) {
                    revert(0, 0)
                }
            }
        } else {
            require(
                Address.isContract(_flowAddress),
                "_flowAddress should be contract"
            );

            unchecked {
                // bytes memory input = abi.encodeWithSelector(
                //     IEvaFlow.create.selector,
                //     flowMetas.length,
                //     abi.encode(_value, _flowCode)
                // );

                // (bool success, bytes memory returndata) = _flowAddress.call{
                //     value: 0
                // }(input);

                // require(success, "call flow fail");
                //   _checkdata = returndata;
                bytes memory input = abi.encode(_flowCode, _value);
                _checkdata = IEvaFlow(_flowAddress).create(
                    flowMetas.length,
                    input
                );
            }
        }

        //transfer(order.owner, total);
        address safes = evaSafesFactory.get(msg.sender);
        (bool succeed, ) = safes.call{value: _value}("");
        require(succeed, "Failed to transfer Ether");

        userMetaMap[msg.sender].ethBal =
            userMetaMap[msg.sender].ethBal +
            Utils.toUint120(gasFee);

        flowMetas.push(
            EvaFlowMeta({
                flowStatus: FlowStatus.Active,
                keepNetWork: _keepNetWork,
                maxVaildBlockNumber: MAX_INT,
                admin: msg.sender,
                lastKeeper: address(0),
                lastExecNumber: block.number,
                lastVersionflow: _flowAddress,
                flowName: _flowName,
                checkData: _checkdata
            })
        );

        unchecked {
            userMetaMap[msg.sender].vaildFlowsNum =
                userMetaMap[msg.sender].vaildFlowsNum +
                1;
        }

        //vaild flow
        uint256 flowId = flowMetas.length - 1;
        // vaildFlows.add(flowid);
        vaildFlows[_keepNetWork].add(flowId);

        emit FlowCreated(msg.sender, flowId, _flowAddress);

        return (flowId, _flowAddress);
    }

    function createEvaSafes(address user) external override {
        require(user != address(0), "zero address");
        evaSafesFactory.create(user);

        // userMetaMap[user] = EvaUserMeta({
        //     ethBal: 0,
        //     gasTokenBal: 0,
        //     vaildFlowsNum: 0
        // });
    }

    function updateFlow(
        uint256 _flowId,
        string memory _flowName,
        bytes memory _flowCode
    ) external override nonReentrant {
        require(_flowId < flowMetas.length, "over bound");
        require(
            msg.sender == flowMetas[_flowId].admin,
            "flow's owner is not y"
        );
        require(
            FlowStatus.Active == flowMetas[_flowId].flowStatus ||
                FlowStatus.Paused == flowMetas[_flowId].flowStatus,
            "flow's status is error"
        );

        KeepNetWork _keepNetWork = flowMetas[_flowId].keepNetWork;

        _beforeCreateFlow(_flowName, _keepNetWork, _flowCode);
        //create
        address addr;
        uint256 size;
        assembly {
            addr := create(0, add(_flowCode, 0x20), mload(_flowCode))
            size := extcodesize(addr)
            if iszero(extcodesize(addr)) {
                revert(0, 0)
            }
        }
        // vaildFlows.remove(_flowId);
        vaildFlows[_keepNetWork].remove(_flowId);
        flowMetas[_flowId].flowName = _flowName;
        flowMetas[_flowId].lastKeeper = address(0);
        flowMetas[_flowId].lastExecNumber = block.number;
        flowMetas[_flowId].lastVersionflow = addr;
        // vaildFlows.add(_flowId);
        vaildFlows[_keepNetWork].add(_flowId);

        emit FlowUpdated(msg.sender, _flowId, addr);
    }

    function pauseFlow(uint256 _flowId, bytes memory _flowCode)
        external
        override
    {
        require(_flowId < flowMetas.length, "over bound");
        require(
            userMetaMap[msg.sender].vaildFlowsNum > 0,
            "vaildFlowsNum should gt 0"
        );
        require(
            FlowStatus.Active == flowMetas[_flowId].flowStatus,
            "flow's status is error"
        );
        require(
            msg.sender == flowMetas[_flowId].admin || msg.sender == owner(),
            "flow's owner is not y"
        );
        flowMetas[_flowId].lastExecNumber = block.number;
        flowMetas[_flowId].flowStatus = FlowStatus.Paused;

        unchecked {
            userMetaMap[msg.sender].vaildFlowsNum =
                userMetaMap[msg.sender].vaildFlowsNum -
                1;
        }

        if (flowMetas[_flowId].lastVersionflow != address(0)) {
            // vaildFlows.remove(_flowId);
            KeepNetWork _keepNetWork = flowMetas[_flowId].keepNetWork;
            vaildFlows[_keepNetWork].remove(_flowId);
        }
        //pause flow IEvaFlow
        IEvaFlow(flowMetas[_flowId].lastVersionflow).pause(_flowId, _flowCode);

        emit FlowPaused(msg.sender, _flowId);
    }

    function startFlow(uint256 _flowId, bytes memory _flowCode)
        external
        override
    {
        require(_flowId < flowMetas.length, "over bound");

        require(
            msg.sender == flowMetas[_flowId].admin || msg.sender == owner(),
            "flow's owner is not y"
        );
        require(
            FlowStatus.Paused == flowMetas[_flowId].flowStatus,
            "flow's status is error"
        );
        flowMetas[_flowId].lastExecNumber = block.number;
        flowMetas[_flowId].flowStatus = FlowStatus.Active;

        unchecked {
            userMetaMap[msg.sender].vaildFlowsNum =
                userMetaMap[msg.sender].vaildFlowsNum +
                1;
        }

        if (flowMetas[_flowId].lastVersionflow != address(0)) {
            // vaildFlows.add(_flowId);
            KeepNetWork _keepNetWork = flowMetas[_flowId].keepNetWork;
            vaildFlows[_keepNetWork].add(_flowId);
        }

        //start flow IEvaFlow
        IEvaFlow(flowMetas[_flowId].lastVersionflow).start(_flowId, _flowCode);

        emit FlowStart(msg.sender, _flowId);
    }

    function destroyFlow(uint256 _flowId, bytes memory _flowCode)
        external
        override
    {
        require(_flowId < flowMetas.length, "over bound");
        require(
            msg.sender == flowMetas[_flowId].admin || msg.sender == owner(),
            "flow's owner is not y"
        );
        require(
            userMetaMap[msg.sender].vaildFlowsNum > 0,
            "vaildFlowsNum should gt 0"
        );
        if (flowMetas[_flowId].lastVersionflow != address(0)) {
            // vaildFlows.remove(_flowId);
            KeepNetWork _keepNetWork = flowMetas[_flowId].keepNetWork;
            vaildFlows[_keepNetWork].remove(_flowId);
        }

        flowMetas[_flowId].lastExecNumber = block.number;
        flowMetas[_flowId].flowStatus = FlowStatus.Destroyed;
        // flowMetas[_flowId].lastVersionflow = address(0);
        unchecked {
            userMetaMap[msg.sender].vaildFlowsNum =
                userMetaMap[msg.sender].vaildFlowsNum -
                1;
        }
        //destroy flow IEvaFlow
        IEvaFlow(flowMetas[_flowId].lastVersionflow).destroy(
            _flowId,
            _flowCode
        );
        emit FlowDestroyed(msg.sender, _flowId);
    }

    function addFundByUser(
        address tokenAdress,
        uint256 amount,
        address user
    ) public payable override nonReentrant {
        require(evaSafesFactory.get(user) != address(0), "safe wallet is 0x");

        unchecked {
            if (tokenAdress == address(0)) {
                require(msg.value == amount, "value is not equal");
                userMetaMap[user].ethBal =
                    userMetaMap[user].ethBal +
                    Utils.toUint120(msg.value);
            } else {
                require(tokenAdress == minConfig.feeToken, "error FeeToken");

                userMetaMap[user].gasTokenBal =
                    userMetaMap[user].gasTokenBal +
                    Utils.toUint120(amount);

                IERC20(tokenAdress).safeTransferFrom(
                    user,
                    address(this),
                    amount
                );
            }
        }
    }

    function withdrawFundByUser(address tokenAdress, uint256 amount)
        external
        override
        nonReentrant
    {
        require(
            evaSafesFactory.get(msg.sender) != address(0),
            "safe wallet is 0x"
        );
        unchecked {
            //        uint64 minGasFundForUser;
            // uint64 minGasFundOneFlow;
            uint256 minTotalFlow = userMetaMap[msg.sender].vaildFlowsNum *
                minConfig.minGasFundOneFlow;
            uint256 minTotalGas = minTotalFlow > minConfig.minGasFundForUser
                ? minTotalFlow
                : minConfig.minGasFundForUser;

            if (tokenAdress == address(0)) {
                require(userMetaMap[msg.sender].ethBal >= amount + minTotalGas);
                userMetaMap[msg.sender].ethBal =
                    userMetaMap[msg.sender].ethBal -
                    Utils.toUint120(amount);
                (bool sent, bytes memory data) = msg.sender.call{value: amount}(
                    ""
                );
                require(sent, "Failed to send Ether");
            } else {
                require(tokenAdress == minConfig.feeToken, "error FeeToken");

                require(userMetaMap[msg.sender].ethBal >= amount + minTotalGas);

                userMetaMap[msg.sender].gasTokenBal =
                    userMetaMap[msg.sender].gasTokenBal -
                    Utils.toUint120(amount);

                IERC20(tokenAdress).transfer(msg.sender, amount);
            }
        }
    }

    function withdrawPayment(address tokenAdress, uint256 amount)
        external
        override
        onlyOwner
    {
        if (tokenAdress == address(0)) {
            require(paymentEthAmount >= amount, "");
            TransferHelper.safeTransferETH(msg.sender, amount);
            // (bool sent, ) = msg.sender.call{value: amount}("");
            // require(sent, "Failed to send Ether");
        } else {
            require(tokenAdress == minConfig.feeToken, "error FeeToken");
            require(paymentGasAmount >= amount, "");
            IERC20(tokenAdress).transfer(msg.sender, amount);
        }
    }

    function getIndexVaildFlow(uint256 _index, KeepNetWork _keepNetWork)
        external
        view
        override
        returns (uint256 value)
    {
        return vaildFlows[_keepNetWork].get(_index);
    }

    function getVaildFlowRange(
        uint256 fromIndex,
        uint256 endIndex,
        KeepNetWork _keepNetWork
    ) external view override returns (uint256[] memory arr) {
        return vaildFlows[_keepNetWork].getRange(fromIndex, endIndex);
    }

    function getAllVaildFlowSize(KeepNetWork _keepNetWork)
        external
        view
        override
        returns (uint256 size)
    {
        return vaildFlows[_keepNetWork].getSize();
    }

    function getFlowMetas(uint256 index)
        external
        view
        override
        returns (EvaFlowMeta memory)
    {
        return flowMetas[index];
    }

    function batchExecFlow(bytes memory _data, uint256 gasLimit)
        external
        override
    {
        uint256 gasTotal = 0;
        // uint256[] memory arr = Utils.decodeUints(_data);
        (uint256[] memory arr, bytes[] memory executeDataArray) = Utils
            ._decodeTwoArr(_data);

        require(arr.length == executeDataArray.length, "arr is empty");

        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] > 0) {
                uint256 before = gasleft();
                execFlow(arr[i], executeDataArray[i]);
                if (gasTotal + before - gasleft() > gasLimit) {
                    return;
                }
            }
        }
    }

    function execFlow(uint256 _flowId, bytes memory _inputData)
        public
        override
        nonReentrant
    {
        require(config.isKeeper(msg.sender), "exect keeper is not whitelist");
        uint256 before = gasleft();
        EvaFlowMeta memory flowMeta = flowMetas[_flowId];
        bool _sucess;
        if (
            flowMeta.lastVersionflow != address(0) &&
            flowMeta.flowStatus == FlowStatus.Active &&
            //keeep is self
            (msg.sender != flowMeta.lastKeeper ||
                flowMeta.keepNetWork != KeepNetWork.ChainLink) &&
            flowMeta.maxVaildBlockNumber >= block.number
            // flowMeta.lastExecNumber + 10 >= block.number
        ) {
            //IEvaFlow(flowMeta.lastVersionflow);

            address admin = flowMeta.admin;
            address safesAdd = evaSafesFactory.get(admin);
            if (safesAdd != address(0)) {
                (, uint256 ethValue) = Utils._decodeUintAndBytes(_inputData);
                bytes[] memory data = new bytes[](1);
                //todo ETH.value>0
                if (ethValue == 0) {
                    data[0] = abi.encode(
                        flowMeta.lastVersionflow,
                        abi.encodeWithSelector(
                            IEvaFlow.execute.selector,
                            _inputData
                        )
                    );

                    try IEvaSafes(safesAdd).multicall(_flowId, data) returns (
                        bytes[] memory results
                    ) {
                        _sucess = true;
                    } catch {
                        _sucess = false;
                    }
                } else {
                    data[0] = abi.encode(
                        flowMeta.lastVersionflow,
                        abi.encodeWithSelector(
                            IEvaFlow.execute.selector,
                            _inputData
                        ),
                        ethValue
                    );

                    try
                        IEvaSafes(safesAdd).multicallWithValue(_flowId, data)
                    returns (bytes[] memory results) {
                        // update
                        // flowMetas[_flowId].lastExecNumber = block.number;
                        // flowMetas[_flowId].lastKeeper = msg.sender;
                        _sucess = true;
                    } catch {
                        _sucess = false;
                    }
                }

                // update
                flowMetas[_flowId].lastExecNumber = block.number;
                // if (flowMeta.keepNetWork != KeepNetWork.ChainLink) {
                flowMetas[_flowId].lastKeeper = msg.sender;
                // }

                uint256 payAmountByETH = 0;
                uint256 payAmountByFeeToken = 0;

                unchecked {
                    uint256 usedGas = before - gasleft();
                    if (minConfig.feeToken == address(0)) {
                        payAmountByETH = calculatePaymentAmount(usedGas);

                        require(payAmountByETH < userMetaMap[admin].ethBal);
                        userMetaMap[admin].ethBal =
                            userMetaMap[admin].ethBal -
                            Utils.toUint120(payAmountByETH);
                    } else {
                        //todo
                    }

                    emit FlowExecuted(
                        msg.sender,
                        _flowId,
                        _sucess,
                        payAmountByETH,
                        payAmountByFeeToken,
                        usedGas
                    );
                }
            }
        }
    }

    function calculatePaymentAmount(uint256 gasLimit)
        private
        view
        returns (uint96 payment)
    {
        uint256 total;
        unchecked {
            uint256 weiForGas = tx.gasprice *
                (gasLimit + REGISTRY_GAS_OVERHEAD);
            // uint256 premium = minConfig.add(config.paymentPremiumPPB);
            total = weiForGas * (minConfig.PPB);
        }
        //require(total <= LINK_TOTAL_SUPPLY, "payment greater than all LINK");
        return uint96(total); // LINK_TOTAL_SUPPLY < UINT96_MAX
    }

    function getSafes(address user) external view override returns (address) {
        return evaSafesFactory.get(user);
    }

    // function execNftLimitOrderFlow(
    //     uint256 _flowId,
    //     uint256 _orderId,
    //     uint256 _value,
    //     address _admin,
    //     uint8 _marketType,
    //     bytes memory _execMarketData
    // ) external nonReentrant {
    //     require(config.isKeeper(msg.sender), "exect keeper is not whitelist");
    //     uint256 before = gasleft();
    //     EvaFlowMeta memory flowMeta = flowMetas[_flowId];
    //     bool _sucess;
    //     if (
    //         flowMeta.flowStatus == FlowStatus.Active &&
    //         flowMeta.maxVaildBlockNumber >= block.number
    //     ) {
    //         address safesAdd = evaSafesFactory.get(_admin);
    //         if (safesAdd != address(0)) {
    //             bytes[] memory data = new bytes[](1);
    //             data[0] = abi.encode(
    //                 flowMeta.lastVersionflow,
    //                 abi.encodeWithSelector(IEvaFlow.execute.selector, "")
    //             );

    //             try
    //                 IEvaSafes(safesAdd).multicallWithValue(_flowId, data)
    //             returns (bytes[] memory results) {
    //                 // update
    //                 flowMetas[_flowId].lastExecNumber = block.number;
    //                 flowMetas[_flowId].lastKeeper = msg.sender;
    //             } catch {
    //                 _sucess = false;
    //             }

    //             uint256 payAmountByETH = 0;
    //             uint256 payAmountByFeeToken = 0;
    //             uint256 afterGas = gasleft();

    //             unchecked {
    //                 if (minConfig.feeToken == address(0)) {
    //                     payAmountByETH = calculatePaymentAmount(
    //                         before - afterGas
    //                     );

    //                     require(payAmountByETH < userMetaMap[_admin].ethBal);
    //                     userMetaMap[_admin].ethBal =
    //                         userMetaMap[_admin].ethBal -
    //                         payAmountByETH;
    //                 } else {
    //                     //todo
    //                 }
    //             }
    //             emit FlowExecuted(
    //                 msg.sender,
    //                 _flowId,
    //                 _sucess,
    //                 payAmountByETH,
    //                 payAmountByFeeToken
    //             );
    //         }
    //     }
    // }

    // function addEvabaseFlowByOwner(
    //     address evabaseFlowAdd,
    //     KeepNetWork _keepNetWork,
    //     string memory name,
    //     bytes memory _checkdata
    // ) external onlyOwner {
    //     flowMetas.push(
    //         EvaFlowMeta({
    //             flowStatus: FlowStatus.Active,
    //             keepNetWork: _keepNetWork,
    //             maxVaildBlockNumber: MAX_INT,
    //             admin: msg.sender,
    //             lastKeeper: address(0),
    //             lastExecNumber: block.number,
    //             lastVersionflow: evabaseFlowAdd,
    //             flowName: name,
    //             checkData: _checkdata
    //         })
    //     );
    //     emit FlowCreated(msg.sender, flowMetas.length - 1, evabaseFlowAdd);
    // }
}