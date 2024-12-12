local capabilities = require "st.capabilities"
local ZigbeeDriver = require "st.zigbee"
local zcl_messages = require "st.zigbee.zcl"
local messages = require "st.zigbee.messages"
local data_types = require "st.zigbee.data_types"
local zb_const = require "st.zigbee.constants"
local generic_body = require "st.zigbee.generic_body"
local log = require "log"

local mode_reset = capabilities["detailprepare34568.modeReset"]

local CLUSTER_TUYA = 0xEF00
local SET_DATA = 0x00
local DP_TYPE_BOOL = "\x01"
local DP_TYPE_ENUM = "\x04"

-- data points
local DP_STATE = "\x01"
local DP_RESTART_MODE = "\x65"
local DP_RF_CONTROL = "\x66"
local DP_RF_PAIRING = "\x67"
local DP_BUZZER_FEEDBACK = "\x68"
local DP_POWER_ON_BEHAVIOR = "\x69"
local DP_CHILD_LOCK = "\x6A"

local packet_id = 0

local function send_tuya_command(device, dp, dp_type, fncmd)
    local header_args = {
        cmd = data_types.ZCLCommandId(SET_DATA)
    }
    local zclh = zcl_messages.ZclHeader(header_args)
    zclh.frame_ctrl:set_cluster_specific()
    local addrh = messages.AddressHeader(
        zb_const.HUB.ADDR,
        zb_const.HUB.ENDPOINT,
        device:get_short_address(),
        device:get_endpoint(CLUSTER_TUYA),
        zb_const.HA_PROFILE_ID,
        CLUSTER_TUYA
    )
    packet_id = (packet_id + 1) % 65536
    local fncmd_len = string.len(fncmd)
    local payload_body = generic_body.GenericBody(string.pack(">I2", packet_id) ..
        dp .. dp_type .. string.pack(">I2", fncmd_len) .. fncmd)
    local message_body = zcl_messages.ZclMessageBody({
        zcl_header = zclh,
        zcl_body = payload_body
    })
    local send_message = messages.ZigbeeMessageTx({
        address_header = addrh,
        body = message_body
    })
    device:send(send_message)
end

local function tuya_cluster_handler(driver, device, zb_rx)
    local rx = zb_rx.body.zcl_body.body_bytes
    local dp = string.byte(rx:sub(3, 3))
    local fncmd_len = string.unpack(">I2", rx:sub(5, 6))
    local fncmd = string.unpack(">I" .. fncmd_len, rx:sub(7))

    if dp == string.byte(DP_STATE) then
        if fncmd == 1 then
            device:emit_event(capabilities.switch.switch.on())
        elseif fncmd == 0 then
            device:emit_event(capabilities.switch.switch.off())
        end
    elseif dp == string.byte(DP_RESTART_MODE) then
        if fncmd == 1 then
            device:emit_event(mode_reset.modeReset("forceReset"))
        elseif fncmd == 2 then
            device:emit_event(mode_reset.modeReset("unused"))
        end
    end
end

-- Device lifecycle handlers
local function device_added(driver, device)
    send_tuya_command(device, DP_BUZZER_FEEDBACK, DP_TYPE_BOOL, device.preferences.buzzer and "\x01" or "\x00")
    send_tuya_command(device, DP_CHILD_LOCK, DP_TYPE_BOOL, device.preferences.childLock and "\x01" or "\x00")
    send_tuya_command(device, DP_POWER_ON_BEHAVIOR, DP_TYPE_ENUM, device.preferences["detailprepare34568.relayStatus"] == "off" and "\x00" or "\x01")
    send_tuya_command(device, DP_RF_CONTROL, DP_TYPE_ENUM, device.preferences.rfControl == "ON" and "\x00" or "\x01")
    send_tuya_command(device, DP_CHILD_LOCK, DP_TYPE_BOOL, device.preferences.childLock and "\x01" or "\x00")
end

local function device_init(driver, device)
    device:emit_event(mode_reset.modeReset.unused())
end

local function device_info_changed(driver, device, event, args)
    log.debug(args.old_st_store.preferences["detailprepare34568.relayStatus"])
    log.debug(device.preferences["detailprepare34568.relayStatus"])
    if args.old_st_store.preferences["detailprepare34568.relayStatus"] ~= device.preferences["detailprepare34568.relayStatus"] then
        send_tuya_command(device, DP_POWER_ON_BEHAVIOR, DP_TYPE_ENUM, device.preferences["detailprepare34568.relayStatus"] == "off" and "\x00" or "\x01")
    end
    if args.old_st_store.preferences.rfControl ~= device.preferences.rfControl then
        send_tuya_command(device, DP_RF_CONTROL, DP_TYPE_ENUM, device.preferences.rfControl == "ON" and "\x00" or "\x01")
    end
    if args.old_st_store.preferences.rfPairing ~= device.preferences.rfPairing then
        send_tuya_command(device, DP_RF_PAIRING, DP_TYPE_BOOL, device.preferences.rfPairing and "\x01" or "\x00")
    end
    if args.old_st_store.preferences.buzzer ~= device.preferences.buzzer then
        send_tuya_command(device, DP_BUZZER_FEEDBACK, DP_TYPE_BOOL, device.preferences.buzzer and "\x01" or "\x00")
    end
    if args.old_st_store.preferences.childLock ~= device.preferences.childLock then
        send_tuya_command(device, DP_CHILD_LOCK, DP_TYPE_BOOL, device.preferences.childLock and "\x01" or "\x00")
    end
end

-- Driver definitions
local weten_tuya_pro = {
    supported_capabilities = {
        capabilities.switch,
        mode_reset
    },
    zigbee_handlers = {
        cluster = {
            [CLUSTER_TUYA] = {
                [0x01] = tuya_cluster_handler,
                [0x02] = tuya_cluster_handler
            }
        }
    },
    capability_handlers = {
        [capabilities.switch.ID] = {
            [capabilities.switch.commands.on.NAME] = function(driver, device)
                send_tuya_command(device, DP_STATE, DP_TYPE_BOOL, "\x01")
            end,
            [capabilities.switch.commands.off.NAME] = function(driver, device)
                send_tuya_command(device, DP_STATE, DP_TYPE_BOOL, "\x00")
            end
        },
        [mode_reset.ID] = {
            [mode_reset.commands.set.NAME] = function (driver, device, command) 
                if command.args.modeReset == "reset" then
                    if device:get_latest_state("main", capabilities.switch.ID, capabilities.switch.switch.NAME) == "on" then
                        send_tuya_command(device, DP_RESTART_MODE, DP_TYPE_ENUM, "\x00")
                        device:emit_event(mode_reset.modeReset("reset"))
                    else
                        device:emit_event(mode_reset.modeReset("reset"))
                        device:emit_event(mode_reset.modeReset("unused"))
                    end
                elseif command.args.modeReset == "forceReset" then
                    if device:get_latest_state("main", capabilities.switch.ID, capabilities.switch.switch.NAME) == "on" then
                        send_tuya_command(device, DP_RESTART_MODE, DP_TYPE_ENUM, "\x01")
                    else
                        device:emit_event(mode_reset.modeReset("forceReset"))
                        device:emit_event(mode_reset.modeReset("unused"))
                    end
                elseif command.args.modeReset == "unused" then
                    device:emit_event(mode_reset.modeReset("unused"))
                end
            end
        }
    },
    lifecycle_handlers = {
        added = device_added,
        init = device_init,
        infoChanged = device_info_changed
    }
}

local zigbee_driver = ZigbeeDriver("weten-tuya-pro", weten_tuya_pro)
zigbee_driver:run()
