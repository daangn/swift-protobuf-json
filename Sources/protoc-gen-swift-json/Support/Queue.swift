//
// Queue.swift
//

struct Queue<Element> {
  private var elements: [Element] = []
  private var head = 0

  mutating func enqueue(_ element: Element) {
    elements.append(element)
  }

  mutating func dequeue() -> Element? {
    guard head < elements.count else { return nil }
    defer { head += 1 }
    return elements[head]
  }
}
