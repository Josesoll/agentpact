// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal interface of the SPACE ID Agent ID registry (ERC-721, non-transferable).
interface IAgentIdRegistry {
    function balanceOf(address owner) external view returns (uint256);
}

/// @notice Minimal ERC-20 interface (USDT/USDC on BNB Chain).
interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @title AgentPact — escrow and reputation for AI agents, gated by Agent ID
/// @notice Agents identified by a Binance Agent ID (name.ai) hire each other safely:
///         the client escrows the payment in this contract, the provider delivers,
///         and the payment is released on confirmation — or automatically after a
///         grace period. Completed jobs build public, permanent reputation.
/// @dev    Single-file contract with no external dependencies. BNB Chain mainnet
///         Agent ID registry: 0x60B9262456De011F7d15a54CdD8C48baaA8b022F.
contract AgentPact {
    // ------------------------------------------------------------------
    // State
    // ------------------------------------------------------------------

    IAgentIdRegistry public immutable agentIdRegistry;

    struct Profile {
        string name;     // display name of the agent
        string skills;   // comma-separated skills
        string endpoint; // URL or handle where the agent can be reached
        bool exists;
    }

    mapping(address => Profile) public profiles;
    address[] public registeredAgents;

    /// @notice Reputation counters, earned only from real escrowed work.
    mapping(address => uint256) public jobsCompleted; // as provider, payment released
    mapping(address => uint256) public jobsFunded;    // as client, payment released
    mapping(address => uint256) public jobsCancelled; // jobs that ended refunded/cancelled

    enum JobState {
        Funded,    // payment escrowed, work not yet delivered
        Delivered, // provider marked the work delivered
        Released,  // payment paid to the provider (terminal)
        Refunded,  // payment returned to the client (terminal)
        Cancelled  // cancelled by mutual path before delivery (terminal)
    }

    struct Job {
        address client;
        address provider;
        address token; // address(0) = native BNB
        uint256 amount;
        string description;
        uint64 deadline;    // provider must deliver by this time
        uint64 deliveredAt; // 0 until delivered
        JobState state;
    }

    Job[] public jobs;

    /// @notice After delivery, if the client stays silent for this long,
    ///         the provider can claim the payment.
    uint256 public constant CLAIM_GRACE = 3 days;

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    event ProfileRegistered(address indexed agent, string name);
    event JobCreated(uint256 indexed jobId, address indexed client, address indexed provider, address token, uint256 amount, uint64 deadline);
    event JobDelivered(uint256 indexed jobId, address indexed provider);
    event JobReleased(uint256 indexed jobId, address indexed provider, uint256 amount);
    event JobRefunded(uint256 indexed jobId, address indexed client, uint256 amount);
    event JobCancelled(uint256 indexed jobId);

    // ------------------------------------------------------------------
    // Guards
    // ------------------------------------------------------------------

    uint256 private _lock = 1;

    modifier nonReentrant() {
        require(_lock == 1, "reentrant call");
        _lock = 2;
        _;
        _lock = 1;
    }

    modifier onlyAgentHolder(address who) {
        require(agentIdRegistry.balanceOf(who) > 0, "Agent ID required");
        _;
    }

    constructor(address registry) {
        require(registry != address(0), "registry is zero");
        agentIdRegistry = IAgentIdRegistry(registry);
    }

    // ------------------------------------------------------------------
    // Agent directory
    // ------------------------------------------------------------------

    /// @notice Register (or update) your agent profile. Requires an Agent ID.
    ///         This is also the one-click interaction any Agent ID holder can
    ///         make to join the directory.
    function registerProfile(
        string calldata name,
        string calldata skills,
        string calldata endpoint
    ) external onlyAgentHolder(msg.sender) {
        if (!profiles[msg.sender].exists) {
            registeredAgents.push(msg.sender);
        }
        profiles[msg.sender] = Profile(name, skills, endpoint, true);
        emit ProfileRegistered(msg.sender, name);
    }

    function registeredCount() external view returns (uint256) {
        return registeredAgents.length;
    }

    function isAgent(address who) public view returns (bool) {
        return agentIdRegistry.balanceOf(who) > 0;
    }

    /// @notice Reputation of an agent: completed jobs, funded jobs, cancellations.
    function reputationOf(address who)
        external
        view
        returns (uint256 completed, uint256 funded, uint256 cancelled)
    {
        return (jobsCompleted[who], jobsFunded[who], jobsCancelled[who]);
    }

    // ------------------------------------------------------------------
    // Escrow jobs
    // ------------------------------------------------------------------

    /// @notice Create a job and escrow the payment.
    /// @param provider Agent ID holder who will do the work.
    /// @param token    ERC-20 token address, or address(0) for native BNB
    ///                 (then msg.value must equal amount).
    /// @param amount   Payment amount in the token's smallest unit.
    /// @param deadline Unix time by which the provider must deliver.
    function createJob(
        address provider,
        address token,
        uint256 amount,
        string calldata description,
        uint64 deadline
    ) external payable onlyAgentHolder(msg.sender) onlyAgentHolder(provider) returns (uint256 jobId) {
        require(provider != address(0) && provider != msg.sender, "bad provider");
        require(amount > 0, "amount is zero");
        require(deadline > block.timestamp, "deadline in past");

        if (token == address(0)) {
            require(msg.value == amount, "BNB amount mismatch");
        } else {
            require(msg.value == 0, "BNB not accepted for token job");
            require(IERC20(token).transferFrom(msg.sender, address(this), amount), "transferFrom failed");
        }

        jobId = jobs.length;
        jobs.push(
            Job({
                client: msg.sender,
                provider: provider,
                token: token,
                amount: amount,
                description: description,
                deadline: deadline,
                deliveredAt: 0,
                state: JobState.Funded
            })
        );
        emit JobCreated(jobId, msg.sender, provider, token, amount, deadline);
    }

    /// @notice Provider marks the work as delivered.
    function markDelivered(uint256 jobId) external {
        Job storage job = _job(jobId);
        require(msg.sender == job.provider, "not the provider");
        require(job.state == JobState.Funded, "not funded");
        job.state = JobState.Delivered;
        job.deliveredAt = uint64(block.timestamp);
        emit JobDelivered(jobId, msg.sender);
    }

    /// @notice Client confirms and releases the escrowed payment to the provider.
    function release(uint256 jobId) external nonReentrant {
        Job storage job = _job(jobId);
        require(msg.sender == job.client, "not the client");
        require(job.state == JobState.Funded || job.state == JobState.Delivered, "not releasable");
        _settle(jobId, job, true);
    }

    /// @notice Provider claims the payment after delivery + grace period
    ///         without a client response.
    function claimAfterDelivery(uint256 jobId) external nonReentrant {
        Job storage job = _job(jobId);
        require(msg.sender == job.provider, "not the provider");
        require(job.state == JobState.Delivered, "not delivered");
        require(block.timestamp >= uint256(job.deliveredAt) + CLAIM_GRACE, "grace period running");
        _settle(jobId, job, true);
    }

    /// @notice Client refunds an undelivered job after its deadline passed.
    function refundAfterDeadline(uint256 jobId) external nonReentrant {
        Job storage job = _job(jobId);
        require(msg.sender == job.client, "not the client");
        require(job.state == JobState.Funded, "not funded");
        require(block.timestamp > job.deadline, "deadline not reached");
        _settle(jobId, job, false);
    }

    /// @notice Either party cancels an undelivered job; the client is refunded.
    function cancelJob(uint256 jobId) external nonReentrant {
        Job storage job = _job(jobId);
        require(msg.sender == job.client || msg.sender == job.provider, "not a party");
        require(job.state == JobState.Funded, "not funded");
        job.state = JobState.Cancelled;
        jobsCancelled[job.client] += 1;
        _pay(job, job.client);
        emit JobCancelled(jobId);
        emit JobRefunded(jobId, job.client, job.amount);
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    function _job(uint256 jobId) internal view returns (Job storage) {
        require(jobId < jobs.length, "no such job");
        return jobs[jobId];
    }

    function _settle(uint256 jobId, Job storage job, bool toProvider) internal {
        if (toProvider) {
            job.state = JobState.Released;
            jobsCompleted[job.provider] += 1;
            jobsFunded[job.client] += 1;
            _pay(job, job.provider);
            emit JobReleased(jobId, job.provider, job.amount);
        } else {
            job.state = JobState.Refunded;
            jobsCancelled[job.client] += 1;
            _pay(job, job.client);
            emit JobRefunded(jobId, job.client, job.amount);
        }
    }

    function _pay(Job storage job, address to) internal {
        if (job.token == address(0)) {
            (bool ok, ) = to.call{value: job.amount}("");
            require(ok, "BNB payment failed");
        } else {
            require(IERC20(job.token).transfer(to, job.amount), "token payment failed");
        }
    }

    function jobsCount() external view returns (uint256) {
        return jobs.length;
    }

    function getJob(uint256 jobId)
        external
        view
        returns (
            address client,
            address provider,
            address token,
            uint256 amount,
            string memory description,
            uint64 deadline,
            uint64 deliveredAt,
            JobState state
        )
    {
        Job storage job = _job(jobId);
        return (
            job.client,
            job.provider,
            job.token,
            job.amount,
            job.description,
            job.deadline,
            job.deliveredAt,
            job.state
        );
    }

    /// @notice Ids of jobs still open for delivery (state Funded), newest
    ///         first, capped at `maxResults`. Lets an agent discover work in
    ///         a single call, without an indexer or a website.
    function openJobIds(uint256 maxResults) external view returns (uint256[] memory ids) {
        uint256 total = jobs.length;
        uint256 count = 0;
        for (uint256 i = 0; i < total && count < maxResults; i++) {
            if (jobs[total - 1 - i].state == JobState.Funded) {
                count++;
            }
        }
        ids = new uint256[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < total && idx < count; i++) {
            uint256 jobId2 = total - 1 - i;
            if (jobs[jobId2].state == JobState.Funded) {
                ids[idx] = jobId2;
                idx++;
            }
        }
        return ids;
    }
}
