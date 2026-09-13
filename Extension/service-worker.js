const nativeHostName = "com.schroneko.autoclickcdppopup.bridge";
let nativePort;
let reconnectTimer;

function connectNativeHost() {
  if (nativePort) {
    return;
  }
  try {
    nativePort = chrome.runtime.connectNative(nativeHostName);
  } catch (error) {
    scheduleReconnect();
    return;
  }
  nativePort.onMessage.addListener(handleNativeMessage);
  nativePort.onDisconnect.addListener(() => {
    nativePort = undefined;
    scheduleReconnect();
  });
}

function scheduleReconnect() {
  if (reconnectTimer) {
    return;
  }
  reconnectTimer = setTimeout(() => {
    reconnectTimer = undefined;
    connectNativeHost();
  }, 1000);
}

function sendNativeMessage(message) {
  connectNativeHost();
  if (!nativePort) {
    return;
  }
  try {
    nativePort.postMessage(message);
  } catch (error) {
    nativePort = undefined;
    scheduleReconnect();
  }
}

function sendResponse(id, ok, result, error) {
  const response = { type: "response", id, ok };
  if (result !== undefined) {
    response.result = result;
  }
  if (error) {
    response.error = error;
  }
  sendNativeMessage(response);
}

function queryTabs() {
  return new Promise((resolve, reject) => {
    chrome.tabs.query({}, tabs => {
      const lastError = chrome.runtime.lastError;
      if (lastError) {
        reject(new Error(lastError.message));
        return;
      }
      resolve(tabs.map(tab => ({
        id: tab.id,
        windowId: tab.windowId,
        index: tab.index,
        active: tab.active,
        pinned: tab.pinned,
        status: tab.status,
        title: tab.title,
        url: tab.url,
        favIconUrl: tab.favIconUrl
      })));
    });
  });
}

function attachDebugger(tabId, version) {
  return new Promise((resolve, reject) => {
    chrome.debugger.attach({ tabId }, version || "1.3", () => {
      const lastError = chrome.runtime.lastError;
      if (lastError) {
        reject(new Error(lastError.message));
        return;
      }
      resolve({ tabId });
    });
  });
}

function detachDebugger(tabId) {
  return new Promise((resolve, reject) => {
    chrome.debugger.detach({ tabId }, () => {
      const lastError = chrome.runtime.lastError;
      if (lastError) {
        reject(new Error(lastError.message));
        return;
      }
      resolve({ tabId });
    });
  });
}

function sendDebuggerCommand(tabId, method, params) {
  return new Promise((resolve, reject) => {
    chrome.debugger.sendCommand({ tabId }, method, params || {}, result => {
      const lastError = chrome.runtime.lastError;
      if (lastError) {
        reject(new Error(lastError.message));
        return;
      }
      resolve(result === undefined ? {} : result);
    });
  });
}

async function handleRequest(message) {
  const method = message.method;
  const params = message.params || {};
  if (method === "tabs.list") {
    return queryTabs();
  }
  if (method === "debugger.attach") {
    return attachDebugger(Number(message.tabId), message.version);
  }
  if (method === "debugger.detach") {
    return detachDebugger(Number(message.tabId));
  }
  if (method === "debugger.command") {
    return sendDebuggerCommand(Number(message.tabId), String(message.command), params);
  }
  throw new Error(`unknown method: ${method}`);
}

function handleNativeMessage(message) {
  if (message.type !== "request" || !message.id) {
    return;
  }
  handleRequest(message)
    .then(result => sendResponse(message.id, true, result))
    .catch(error => sendResponse(message.id, false, undefined, String(error.message || error)));
}

chrome.debugger.onEvent.addListener((source, method, params) => {
  sendNativeMessage({
    type: "event",
    event: {
      source,
      method,
      params: params || {}
    }
  });
});

chrome.debugger.onDetach.addListener((source, reason) => {
  sendNativeMessage({
    type: "event",
    event: {
      source,
      method: "Target.detached",
      params: { reason }
    }
  });
});

chrome.runtime.onStartup.addListener(connectNativeHost);
chrome.runtime.onInstalled.addListener(connectNativeHost);
connectNativeHost();
