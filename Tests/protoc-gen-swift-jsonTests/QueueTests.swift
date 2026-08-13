//
// QueueTests.swift
//

import Testing

@testable import protoc_gen_swift_json

@Suite("Queue")
struct QueueTests {

  @Test("dequeue returns nil when the queue is empty")
  func emptyQueue() {
    var queue = Queue<Int>()

    #expect(queue.dequeue() == nil)
  }

  @Test("dequeue returns values in insertion order")
  func fifoOrder() {
    var queue = Queue<String>()

    queue.enqueue("first")
    queue.enqueue("second")
    queue.enqueue("third")

    #expect(queue.dequeue() == "first")
    #expect(queue.dequeue() == "second")
    #expect(queue.dequeue() == "third")
    #expect(queue.dequeue() == nil)
  }

  @Test("enqueue after dequeue appends to the back")
  func enqueueAfterDequeue() {
    var queue = Queue<Int>()

    queue.enqueue(1)
    queue.enqueue(2)

    #expect(queue.dequeue() == 1)

    queue.enqueue(3)

    #expect(queue.dequeue() == 2)
    #expect(queue.dequeue() == 3)
    #expect(queue.dequeue() == nil)
  }
}
