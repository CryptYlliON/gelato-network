import { task, types } from "@nomiclabs/buidler/config";
import { defaultNetwork } from "../../../../../buidler.config";
import { utils, constants } from "ethers";

export default task(
  "gc-multiprovide",
  `Sends tx and --funds to GelatoCore.multiProvide() on [--network] (default: ${defaultNetwork})`
)
  .addOptionalParam("funds", "The amount of ETH funds to provide", "0")
  .addOptionalParam(
    "gelatoexecutor",
    "The provider's assigned gelatoExecutor",
    constants.AddressZero
  )
  .addOptionalParam("taskSpecs", "Already created TaskSpecs", [], types.json)
  .addOptionalParam(
    "modules",
    "Gelato Provider Modules. Only 1 via CLI.",
    [],
    types.json
  )
  .addOptionalParam(
    "providerindex",
    "index of user account generated by mnemonic to fetch provider address",
    2,
    types.int
  )
  .addOptionalParam("gelatocoreaddress", "Provide this if not in bre-config")
  .addFlag("events", "Logs parsed Event Logs to stdout")
  .addFlag("log", "Logs return values to stdout")
  .setAction(async (taskArgs) => {
    try {
      // TaskArgs Sanitzation
      // Gelato Provider is the 3rd signer account
      const {
        [taskArgs.providerindex]: gelatoProvider,
      } = await ethers.getSigners();

      if (!gelatoProvider)
        throw new Error("\n gelatoProvider not instantiated \n");

      if (taskArgs.log) console.log("\n gc-multiprovide TaskArgs:\n", taskArgs);

      const gelatoCore = await run("instantiateContract", {
        contractname: "GelatoCore",
        contractaddress: taskArgs.gelatocoreaddress,
        signer: gelatoProvider,
        write: true,
      });

      // GelatoCore contract call from provider account
      // address _executor,
      // TaskSpec[] memory _taskSpecs,
      // IGelatoProviderModule[] memory _modules
      const tx = await gelatoCore.multiProvide(
        taskArgs.gelatoexecutor,
        taskArgs.taskSpecs,
        taskArgs.modules,
        {
          value: utils.parseEther(taskArgs.funds),
        }
      );

      if (taskArgs.log) console.log(`\n\ntxHash multiProvide: ${tx.hash}`);
      const { blockHash: blockhash } = await tx.wait();

      if (taskArgs.events) {
        await run("event-getparsedlogsallevents", {
          contractname: "GelatoCore",
          contractaddress: gelatoCore.address,
          blockhash,
          txhash: tx.hash,
          log: true,
        });
      }

      return tx.hash;
    } catch (error) {
      console.error(error, "\n");
      process.exit(1);
    }
  });
