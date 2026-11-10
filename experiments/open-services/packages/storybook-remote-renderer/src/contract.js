// The remote-renderer contract. A framework's runtime (a native app on a
// simulator or device) implements `remote-renderer/peer`; the dev server
// implements `remote-renderer/hub`. Everything else in this package is
// framework-neutral and built on these two services.
//
// Wire: the peer joins `/storybook-server-channel?token=…` and speaks the
// Open Services events (`services:command-invoke/ack/result/error`).
import * as v from 'valibot';

const json = v.record(v.string(), v.any());
const target = { peerId: v.optional(v.string()) };

/** Implemented by the peer. Inputs carry `peerId` because Open Services broadcasts invokes. */
export const peerService = {
  id: 'remote-renderer/peer',
  description: 'Commands a connected renderer peer runs.',
  initialState: {},
  queries: {},
  commands: {
    describe: { description: 'Peer info plus every story with argTypes and initial args.', input: v.object(target), output: v.any() },
    render: {
      description: 'Render a story and return a PNG (base64).',
      input: v.object({ storyId: v.string(), args: v.optional(json), globals: v.optional(json), bleed: v.optional(v.number()), ...target }),
      output: v.any(),
    },
    select: { description: 'Show a story.', input: v.object({ storyId: v.string(), ...target }), output: v.any() },
    setArgs: { description: 'Merge-patch story args.', input: v.object({ storyId: v.string(), args: json, ...target }), output: v.any() },
    resetArgs: { description: 'Restore initial args.', input: v.object({ storyId: v.string(), ...target }), output: v.any() },
    setGlobals: { description: 'Merge-patch globals.', input: v.object({ globals: json, ...target }), output: v.any() },
    listActions: { description: 'Actions fired on the peer.', input: v.object({ storyId: v.optional(v.string()), ...target }), output: v.any() },
  },
};

/**
 * Implemented by the dev server. Its state is the server-side record of what
 * the peers report, so any runtime (an attached CLI, a script, a manager if
 * one exists) can read story metadata without a browser preview.
 */
export const hubService = {
  id: 'remote-renderer/hub',
  description: 'Connected renderer peers, the story metadata they report, and a relay to them.',
  initialState: { peers: {}, stories: {}, actions: [] },
  queries: {
    peers: { description: 'Connected peers by id.', input: v.void(), output: v.any(), handler: (_i, ctx) => ctx.self.state.peers },
    stories: { description: 'Story metadata (argTypes, initial args) by story id.', input: v.void(), output: v.any(), handler: (_i, ctx) => ctx.self.state.stories },
  },
  commands: {
    // Called by peers.
    peerConnected: { description: 'A peer joined; input is its `describe` output.', input: v.looseObject({ peerId: v.string() }), output: v.any() },
    heartbeat: { description: 'A peer is still there.', input: v.object({ peerId: v.string() }), output: v.any() },
    peerEvent: { description: 'Peer store events: storySelected, argsChanged, globalsChanged, actionFired.', input: v.object({ peerId: v.string(), event: v.string(), data: v.any() }), output: v.any() },
    // Called by tools. Hub handlers are the only route to a peer: command
    // invokes are not relayed between clients, and replicas may not have
    // synced when a handler runs.
    snapshot: { description: 'The hub state, read at the source.', input: v.object({}), output: v.any() },
    call: { description: 'Run a peer command through the hub.', input: v.object({ command: v.string(), input: json }), output: v.any() },
  },
};
