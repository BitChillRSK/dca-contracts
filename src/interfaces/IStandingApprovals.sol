// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/**
 * @title IStandingApprovals
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice The maintenance call that puts a handler's standing token approvals back.
 */
interface IStandingApprovals {
    /**
     * @notice Re-grant every standing approval this handler was given at construction.
     * @dev Unpermissioned by design, and safe to be: it takes no arguments and reads no storage a caller
     *      controls, so all it can do is restore the same unbounded allowance to the same immutable
     *      spenders the constructor already chose. It widens nothing, names nobody new, and calling it
     *      repeatedly is indistinguishable from calling it once.
     *
     *      Call it when a handler's deposits or purchases begin reverting on an allowance. The grants are
     *      made only at construction, so an allowance cleared from outside would otherwise leave that
     *      path dead on a contract that cannot be upgraded. It is not a revoke or a rotate: there is no
     *      way to reduce an allowance or point one somewhere else. On a handler that approves nobody it
     *      does nothing. No event of its own — the token's `Approval` is the log.
     */
    function restoreStandingApprovals() external;
}
