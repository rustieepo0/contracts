-- Import required modules
local ao = require('ao')
local json = require("json")

-- Import custom modules
local bint = require('.bint')(256)
local utils = require(".utils")

-- Global variables
--@type {[string]: string}
Balances = Balances or { [ao.id] = tostring(bint(1e18)) }
--@type string
Name = Name or "Bundler"
--@type string
Ticker = Ticker or "BUN"
--@type integer
Denomination = Denomination or 18
--@type string
Logo = "SBCCXwwecBlDqRLUjb8dYABExTJXLieawf7m2aBJ-KY"
--@type {[string]:{status: string, quantity: string, bundler: string, block: string, transaction: string}}
Uploads = Uploads or {}
--@type {id: string, url: string, reputation: integer}[]
Stakers = Stakers or {}

-- Function to adjust staker reputation
--@param stakerId string
--@param adjustment integer
function AdjustReputation(stakerId, adjustment)
    for i = 1, #Stakers do
        if Stakers[i].id == stakerId then
            Stakers[i].reputation = Stakers[i].reputation + adjustment
            -- Ensure reputation is within a certain range (optional)
            Stakers[i].reputation = math.max(0, Stakers[i].reputation)
            Stakers[i].reputation = math.min(1000, Stakers[i].reputation)
            break
        end
    end
end

-- Function to decrease reputation for incorrect behavior
function Penalize(stakerId)
    AdjustReputation(stakerId, -20) -- Penalize by reducing reputation by 20 points
end

-- Function to check staker reputation
--@param stakerId string
--@param threshold integer
--@return boolean
function CheckReputation(stakerId, threshold)
    for i = 1, #Stakers do
        if Stakers[i].id == stakerId then
            return Stakers[i].reputation >= threshold
        end
    end
    return false
end

-- Update Stakers table structure to include reputation
--@type {id: string, url: string, reputation: integer}[]
Stakers = Stakers or {}

-- Transfer function

--@param sender string
--@param recipient string
--@param quantity Bint
--@param cast unknown
function Transfer(sender, recipient, quantity, cast)
    Balances[sender] = Balances[sender] or tostring(0)
    Balances[recipient] = Balances[recipient] or tostring(0)

    local balance = bint(Balances[sender])
    if bint.__le(quantity, balance) then
        Balances[sender] = tostring(bint.__sub(balance, quantity))
        Balances[recipient] = tostring(bint.__add(Balances[recipient], quantity))

        if not cast then
            ao.send({
                Target = sender,
                Action = 'Debit-Notice',
                Recipient = recipient,
                Quantity = tostring(quantity),
                Data = Colors.gray ..
                    "You transferred " ..
                    Colors.blue .. tostring(quantity) .. Colors.gray .. " to " .. Colors.green .. recipient .. Colors.reset
            })
            -- Send Credit-Notice to the Recipient
            ao.send({
                Target = recipient,
                Action = 'Credit-Notice',
                Sender = sender,
                Quantity = tostring(quantity),
                Data = Colors.gray ..
                    "You received " ..
                    Colors.blue .. tostring(quantity) .. Colors.gray .. " from " .. Colors.green .. sender .. Colors.reset
            })
        end
    else
        ao.send({
            Target = sender,
            Action = 'Transfer-Error',
            Error = 'Insufficient Balance!'
        })
    end
end

-- Verify an upload
--@param id string
function GetVerificationMessage(id)
    ao.send({
        Target = ao.id,
        Tags = {
            Load = id,
            Action = "Data"
        }
    })
end

-- Verify an upload
--@param id string
--@return boolean
function Verify(id)
    local find = utils.find(
        --@param val Message
        function(val)
            return val.Tags["Id"] == id
        end,
        Inbox
    )
    return find ~= nil
end

-- Network Handlers
Handlers.add(
    'initiate',
    Handlers.utils.hasMatchingTag('Action', 'Initiate'),
    function(message, _)
        ---@type string
        local id = message.Data
        assert(id and #id > 0, "Invalid DataItemId")
        assert(Uploads[id] == nil, "Already Queued")

        ---@type Bint
        local quantity = bint(message.Tags.Quantity)
        assert(quantity > 0, "Invalid Quantity")

        assert(Balances[message.From] and bint(Balances[message.From]) >= quantity, "Insufficient Balance")
        Transfer(message.From, ao.id, quantity, false)

        Uploads[id] = {
            status = "0",
            quantity = tostring(quantity),
            bundler = tostring(math.random(#Stakers)),
            block = tostring(message['Block-Height'])
        }
    end
)

--- Vault
Handlers.add(
    'stake',
    Handlers.utils.hasMatchingTag('Action', 'Stake'),
    function(message, _)
        local exist = utils.includes(message.From, Stakers)
        assert(not exist, "Already staked")

        assert(bint(Balances[message.From]) >= bint("1000"), "Insufficient Balance")

        local url = message.Tags.Url;
        assert(url and #url > 0, "Invalid URL")

        Transfer(message.From, ao.id, bint("1000"), false)
        table.insert(Stakers, { id = message.From, url = url, reputation = 1000 })
    end
)

Handlers.add(
    'unstake',
    Handlers.utils.hasMatchingTag('Action', 'Unstake'),
    function(message, _)
        local pos = -1
        for i = 1, #Stakers do
            if Stakers[i].id == message.From then
                pos = i
            end
        end
        assert(pos ~= -1, "Not Staked")

        Transfer(ao.id, message.From, bint("1000"), false)
        table.remove(Stakers, pos)
    end
)

Handlers.add(
    'transfer',
    Handlers.utils.hasMatchingTag('Action', 'Transfer'),
    function(message, _)
        assert(type(message.Tags.Recipient) == 'string', 'Recipient is required!')
        assert(type(message.Tags.Quantity) == 'string', 'Quantity is required!')

        local quantity = bint(message.Tags.Quantity)
        assert(quantity > bint(0), 'Quantity is required!')

        Transfer(message.From, message.Tags.Recipient, quantity, message.Tags.Cast)
    end
)

Handlers.add(
    'notify',
    Handlers.utils.hasMatchingTag('Action', 'Notify'),
    function(message, _)
        local id = message.Tags.DataItemId
        assert(id and #id > 0, "Invalid DataItemId")

        local index = tonumber(Uploads[id].bundler, 10)
        assert(Stakers[index].id == message.From, "Not Assigned")

        assert(Uploads[id].status ~= "2", "Upload Already Complete")

        local transactionId = message.Tags.TransactionId
        assert(transactionId and #transactionId > 0, "Invalid Transaction Id")

        GetVerificationMessage(transactionId)

        Uploads[id].status = "1"
        Uploads[id].transaction = transactionId
    end
)

--- Bundeler can release its reward

Handlers.add(
    'release',
    Handlers.utils.hasMatchingTag('Action', 'Release'),
    function(message, _)
        local id = message.Tags.DataItemId
        assert(id and #id > 0, "Invalid DataItemId")

        local index = tonumber(Uploads[id].bundler, 10)
        assert(Stakers[index].id == message.From, "Not Assigned")

        assert(Uploads[id].status == "1", "Upload incomplete")

        -- Check staker's reputation before releasing reward
        if CheckReputation(message.From, 500) then
            -- If reputation is sufficient, proceed with reward release
            if Verify(Uploads[id].transaction) then
                Uploads[id].status = "2"
                Transfer(ao.id, message.From, bint(Uploads[id].quantity), false)
            else
                Uploads[id].status = "-1"
            end
        else
            -- Penalize staker for insufficient reputation
            Penalize(message.From)
            -- Optionally, we can handle the case where the staker's reputation is too low to release the reward
        end
    end
)

Handlers.add(
    'uploads',
    Handlers.utils.hasMatchingTag('Action', 'Uploads'),
    function(message, _) ao.send({ Target = message.From, Data = json.encode(Uploads) }) end
)

Handlers.add(
    'upload',
    Handlers.utils.hasMatchingTag('Action', 'Upload'),
    function(message, _)
        ao.send({ Target = message.From, Data = json.encode(Uploads[message.Data]) })
    end
)

Handlers.add(
    'balances',
    Handlers.utils.hasMatchingTag('Action', 'Balances'),
    function(message, _) ao.send({ Target = message.From, Data = json.encode(Balances) }) end
)

Handlers.add(
    'stakers',
    Handlers.utils.hasMatchingTag('Action', 'Stakers'),
    function(message, _)
        ao.send({ Target = message.From, Data = json.encode(Stakers) })
    end
)

Handlers.add(
    'staker',
    Handlers.utils.hasMatchingTag('Action', 'Staker'),
    function(message, _)
        ao.send({ Target = message.From, Data = json.encode(Stakers[tonumber(message.Data, 10)]) })
    end
)

Handlers.add(
    'staked',
    Handlers.utils.hasMatchingTag('Action', 'Staked'),
    function(message, _)
        local found = utils.find(
            function(val)
                return val.id == message.From
            end,
            Stakers
        )

        if found then Data = "Yes" else Data = "No" end
        ao.send({ Target = message.From, Data = Data })
    end
)
