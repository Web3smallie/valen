import { publicClient } from "../chain/publicClient.js";
import { contracts } from "../config/contracts.js";
import { LoanRegistryAbi } from "../abis/LoanRegistry.js";
import { RevenueRouterAbi } from "../abis/RevenueRouter.js";

export function startLoanEventListeners() {
  const unwatchRequested = publicClient.watchContractEvent({
    address: contracts.loanRegistry,
    abi: LoanRegistryAbi,
    eventName: "LoanRequested",
    onLogs: (logs) => {
      for (const log of logs) {
        console.log("[LoanRequested]", log.args);
      }
    },
  });

  const unwatchApproved = publicClient.watchContractEvent({
    address: contracts.loanRegistry,
    abi: LoanRegistryAbi,
    eventName: "LoanApproved",
    onLogs: (logs) => {
      for (const log of logs) {
        console.log("[LoanApproved]", log.args);
      }
    },
  });

  const unwatchFunded = publicClient.watchContractEvent({
    address: contracts.loanRegistry,
    abi: LoanRegistryAbi,
    eventName: "LoanFunded",
    onLogs: (logs) => {
      for (const log of logs) {
        console.log("[LoanFunded]", log.args);
      }
    },
  });

  const unwatchMilestone = publicClient.watchContractEvent({
    address: contracts.loanRegistry,
    abi: LoanRegistryAbi,
    eventName: "MilestoneReleased",
    onLogs: (logs) => {
      for (const log of logs) {
        console.log("[MilestoneReleased]", log.args);
      }
    },
  });

  const unwatchStatus = publicClient.watchContractEvent({
    address: contracts.loanRegistry,
    abi: LoanRegistryAbi,
    eventName: "LoanStatusChanged",
    onLogs: (logs) => {
      for (const log of logs) {
        console.log("[LoanStatusChanged]", log.args);
      }
    },
  });

  const unwatchDefaulted = publicClient.watchContractEvent({
    address: contracts.loanRegistry,
    abi: LoanRegistryAbi,
    eventName: "LoanDefaulted",
    onLogs: (logs) => {
      for (const log of logs) {
        console.log("[LoanDefaulted]", log.args);
      }
    },
  });

  const unwatchRevenue = publicClient.watchContractEvent({
    address: contracts.revenueRouter,
    abi: RevenueRouterAbi,
    eventName: "RevenueReceived",
    onLogs: (logs) => {
      for (const log of logs) {
        console.log("[RevenueReceived]", log.args);
      }
    },
  });

  const unwatchSelfRepay = publicClient.watchContractEvent({
    address: contracts.revenueRouter,
    abi: RevenueRouterAbi,
    eventName: "SelfRepayment",
    onLogs: (logs) => {
      for (const log of logs) {
        console.log("[SelfRepayment]", log.args);
      }
    },
  });

  const unwatchRecovered = publicClient.watchContractEvent({
    address: contracts.revenueRouter,
    abi: RevenueRouterAbi,
    eventName: "RepaymentRecovered",
    onLogs: (logs) => {
      for (const log of logs) {
        console.log("[RepaymentRecovered]", log.args);
      }
    },
  });

  const unwatchFullyRepaid = publicClient.watchContractEvent({
    address: contracts.revenueRouter,
    abi: RevenueRouterAbi,
    eventName: "LoanFullyRepaid",
    onLogs: (logs) => {
      for (const log of logs) {
        console.log("[LoanFullyRepaid]", log.args);
      }
    },
  });

  console.log("Loan event listeners started.");

  return () => {
    unwatchRequested();
    unwatchApproved();
    unwatchFunded();
    unwatchMilestone();
    unwatchStatus();
    unwatchDefaulted();
    unwatchRevenue();
    unwatchSelfRepay();
    unwatchRecovered();
    unwatchFullyRepaid();
  };
}