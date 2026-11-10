# Packet driver for MS-DOS networking (NE2000)

`NE2000.COM` is the Crynwr packet driver for NE2000 network cards, from the Crynwr packet driver collection
(http://crynwr.com/drivers/pktd11.zip, sha256 `5dbf0d46...b240c`; the zip's `NE2000.COM` sha256 `69573724...bc12`),
released under the GNU GPL (`GPL.DOC`, `COPYING.DOC`; the collection's source is in the same zip). It is unmodified.
A DOS program that uses the network (Watt-32) needs a packet driver loaded first: DOSBox-X's emulated NE2000 is
`NE2000.COM 0x60 3 0x300`; real hardware takes the driver for its own card.
