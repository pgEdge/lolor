// Import the required modules
var pg = require('pg');
const lo_methods = require('./lo_methods');

describe("lo_methods", () => {
  it('Basic data lo write and read test', async() => {
      const inputData = Buffer.from('0123456789abcdefghijklmnopqrstuvwxyz', 'utf8');
      const oid = await lo_methods.loWrite(inputData);
      const retrievedData = await lo_methods.loRead(oid, inputData.byteLength);
      expect(retrievedData.toString()).toBe(inputData.toString());
      lo_methods.loUnlink(oid);
    });

    it('Basic data lo seek test', async() => {
      const inputData = Buffer.from('0123456789abcdefghijklmnopqrstuvwxyz', 'utf8');
      const changeData = Buffer.from('<ADDEDDATA>', 'utf8');
      const expectedData = "0123456789abcde<ADDEDDATA>qrstuvwxyz";
      const oid = await lo_methods.loWrite(inputData);
      const pos = await lo_methods.loSeek(oid, changeData);
      const retrievedData = await lo_methods.loRead(oid, inputData.byteLength);
      expect(retrievedData.toString()).toBe(expectedData);
      expect(pos).toBe("15");
      lo_methods.loUnlink(oid);
    });

    it('Basic data lo tell test', async() => {
      const inputData = Buffer.from('0123456789abcdefghijklmnopqrstuvwxyz', 'utf8');
      const changeData = Buffer.from('<ADDEDDATA>', 'utf8');
      const expectedData = "<ADDEDDATA>bcdefghijklmnopqrstuvwxyz";
      const oid = await lo_methods.loWrite(inputData);
      const [pos1, pos2] = await lo_methods.loTell(oid, changeData);
      const retrievedData = await lo_methods.loRead(oid, inputData.byteLength);
      expect(retrievedData.toString()).toBe(expectedData);
      expect(pos1).toBe("0");
      expect(pos2).toBe("11");
      lo_methods.loUnlink(oid);
    });

    it('Basic data lo truncate test', async() => {
      const inputData = Buffer.from('0123456789abcdefghijklmnopqrstuvwxyz', 'utf8');
      const expectedData = "0123456789";
      size = 10;
      const oid = await lo_methods.loWrite(inputData);
      await lo_methods.loTruncate(oid, size);
      const retrievedData = await lo_methods.loRead(oid, inputData.byteLength);
      expect(retrievedData.toString()).toBe(expectedData);
      lo_methods.loUnlink(oid);
    });
});