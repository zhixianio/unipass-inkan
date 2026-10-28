// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {SafeWebAuthnBehaviour} from "./SafeWebAuthnBehaviour.sol";
import {LocalDeployment, SepoliaForkDeployment} from "./utils/Deployments.sol";
import {SafeDeployments} from "../src/SafeDeployments.sol";

contract SafeWebAuthnLocalTest is LocalDeployment, SafeWebAuthnBehaviour {}

contract SafeWebAuthnFork130Test is SepoliaForkDeployment, SafeWebAuthnBehaviour {
    function _safeDeployment() internal pure override returns (SafeDeployments.Deployment memory) {
        return SafeDeployments.v130();
    }
}

contract SafeWebAuthnFork141Test is SepoliaForkDeployment, SafeWebAuthnBehaviour {
    function _safeDeployment() internal pure override returns (SafeDeployments.Deployment memory) {
        return SafeDeployments.v141();
    }
}

contract SafeWebAuthnFork150Test is SepoliaForkDeployment, SafeWebAuthnBehaviour {
    function _safeDeployment() internal pure override returns (SafeDeployments.Deployment memory) {
        return SafeDeployments.v150();
    }
}
