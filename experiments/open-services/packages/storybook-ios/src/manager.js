// A manager panel that reads `ios/bridge` state through Open Services sync:
// the server writes it, the manager replica re-renders.
import React from 'react';
import { addons, registerService, types, useServiceQuery } from 'storybook/manager-api';

import { iosBridgeService } from './services.js';

// Registered inside `addons.register`: at module top level the manager has
// no channel yet and `registerService` throws (OpenServiceMissingChannelError).
let devicesQuery;

const h = React.createElement;

function DevicesPanel({ active }) {
  const { data: devices } = useServiceQuery(devicesQuery);
  if (!active) return null;
  const list = Object.entries(devices ?? {});
  if (list.length === 0) {
    return h('p', { style: { padding: 16 } }, 'No iOS devices connected. Launch the host app with -StorybookServer <url>.');
  }
  return h(
    'ul',
    { style: { padding: 16, margin: 0, listStyle: 'none', display: 'grid', gap: 8 } },
    list.map(([id, device]) =>
      h(
        'li',
        { key: id },
        h('strong', null, device.name),
        ` · ${device.osVersion} · ${device.storyCount} stories · showing `,
        h('code', null, device.selected ?? 'nothing'),
        h('div', { style: { opacity: 0.6, fontSize: 12 } }, `${id} · last seen ${new Date(device.lastSeen).toLocaleTimeString()}`)
      )
    )
  );
}

addons.register('storybook-ios', () => {
  devicesQuery = registerService(iosBridgeService).queries.devices;
  addons.add('storybook-ios/devices', {
    type: types.PANEL,
    title: 'iOS devices',
    render: ({ active }) => h(DevicesPanel, { active }),
  });
});
