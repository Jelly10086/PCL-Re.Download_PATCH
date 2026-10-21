using System;
using System.Linq;
using System.Collections.Generic;
using Mono.Cecil;
using Mono.Cecil.Cil;

public sealed class RestoreDownload {
    readonly ModuleDefinition source, target;
    readonly Dictionary<string, TypeDefinition> types = new Dictionary<string, TypeDefinition>();
    readonly Dictionary<string, MethodDefinition> methods = new Dictionary<string, MethodDefinition>();
    readonly Dictionary<string, FieldDefinition> fields = new Dictionary<string, FieldDefinition>();
    readonly List<string> changed = new List<string>();
    readonly Dictionary<GenericParameter,GenericParameter> genericParameters = new Dictionary<GenericParameter,GenericParameter>();
    RestoreDownload(ModuleDefinition s, ModuleDefinition t) {
        source=s; target=t;
        foreach(var x in All(t.Types)) {
            types[x.FullName]=x;
            foreach(var m in x.Methods) methods[m.FullName]=m;
            foreach(var f in x.Fields) fields[f.FullName]=f;
        }
    }
    static IEnumerable<TypeDefinition> All(IEnumerable<TypeDefinition> roots) {
        foreach(var t in roots) { yield return t; foreach(var n in All(t.NestedTypes)) yield return n; }
    }
    bool Local(TypeReference t) {
        while(t is TypeSpecification) t=((TypeSpecification)t).ElementType;
        return t.Scope == source || (t.Scope is AssemblyNameReference && t.Scope.Name==source.Assembly.Name.Name);
    }
    TypeReference T(TypeReference t) {
        var g=t as GenericInstanceType;
        if(g!=null) { var n=new GenericInstanceType(T(g.ElementType)); foreach(var a in g.GenericArguments)n.GenericArguments.Add(T(a)); return n; }
        var arr=t as ArrayType;
        if(arr!=null)return new ArrayType(T(arr.ElementType),arr.Rank);
        if(t is ByReferenceType)return new ByReferenceType(T(((ByReferenceType)t).ElementType));
        if(t is PointerType)return new PointerType(T(((PointerType)t).ElementType));
        var p=t as GenericParameter;
        if(p!=null) {
            GenericParameter mapped;
            if(genericParameters.TryGetValue(p,out mapped))return mapped;
            var owner=p.Owner as TypeReference;
            if(owner!=null) return T(owner).GenericParameters[p.Position];
            return p;
        }
        if(!Local(t))return target.ImportReference(t);
        TypeDefinition found;
        if(types.TryGetValue(t.FullName,out found))return found;
        var def=t.Resolve();
        if(!def.Name.StartsWith("_Closure$"))throw new Exception("Missing type: "+t.FullName);
        var parent=(TypeDefinition)T(def.DeclaringType);
        found=new TypeDefinition(def.Namespace,def.Name,def.Attributes,T(def.BaseType));
        parent.NestedTypes.Add(found); types[def.FullName]=found;
        foreach(var f in def.Fields) {
            var nf=new FieldDefinition(f.Name,f.Attributes,T(f.FieldType));
            found.Fields.Add(nf); fields[f.FullName]=nf;
        }
        foreach(var m in def.Methods) {
            var nm=new MethodDefinition(m.Name,m.Attributes,T(m.ReturnType));
            foreach(var a in m.Parameters) nm.Parameters.Add(new ParameterDefinition(a.Name,a.Attributes,T(a.ParameterType)));
            found.Methods.Add(nm); methods[m.FullName]=nm;
        }
        foreach(var m in def.Methods) if(m.HasBody) Copy(m,methods[m.FullName]);
        changed.Add("Restored closure "+def.FullName);
        return found;
    }
    FieldReference F(FieldReference f) {
        if(!Local(f.DeclaringType))return new FieldReference(f.Name,T(f.FieldType),T(f.DeclaringType));
        var owner=T(f.DeclaringType);
        FieldDefinition found;
        if(fields.TryGetValue(f.FullName,out found))return found;
        if(f.DeclaringType is GenericInstanceType)return new FieldReference(f.Name,T(f.FieldType),owner);
        throw new Exception("Missing field: "+f.FullName);
    }
    MethodReference M(MethodReference m) {
        var gm=m as GenericInstanceMethod;
        if(gm!=null) {var n=new GenericInstanceMethod(M(gm.ElementMethod));foreach(var a in gm.GenericArguments)n.GenericArguments.Add(T(a));return n;}
        if(!Local(m.DeclaringType)) {
            var n=new MethodReference(m.Name,target.TypeSystem.Void,T(m.DeclaringType)) {HasThis=m.HasThis,ExplicitThis=m.ExplicitThis,CallingConvention=m.CallingConvention};
            foreach(var gp in m.GenericParameters) {var ng=new GenericParameter(gp.Name,n);n.GenericParameters.Add(ng);genericParameters[gp]=ng;}
            n.ReturnType=T(m.ReturnType);
            foreach(var a in m.Parameters)n.Parameters.Add(new ParameterDefinition(T(a.ParameterType)));
            return n;
        }
        var owner=T(m.DeclaringType);
        MethodDefinition found;
        if(methods.TryGetValue(m.FullName,out found))return found;
        if(m.DeclaringType is GenericInstanceType) {
            var n=new MethodReference(m.Name,T(m.ReturnType),owner) {HasThis=m.HasThis,ExplicitThis=m.ExplicitThis,CallingConvention=m.CallingConvention};
            foreach(var a in m.Parameters)n.Parameters.Add(new ParameterDefinition(T(a.ParameterType)));
            foreach(var gp in m.GenericParameters)n.GenericParameters.Add(new GenericParameter(gp.Name,n));
            return n;
        }
        if(!m.Name.StartsWith("_Lambda$"))throw new Exception("Missing method: "+m.FullName);
        var def=m.Resolve();
        found=new MethodDefinition(def.Name,def.Attributes,T(def.ReturnType));
        foreach(var a in def.Parameters)found.Parameters.Add(new ParameterDefinition(a.Name,a.Attributes,T(a.ParameterType)));
        ((TypeDefinition)owner).Methods.Add(found); methods[m.FullName]=found;
        Copy(def,found); changed.Add("Restored delegate "+def.FullName);return found;
    }
    void Copy(MethodDefinition from,MethodDefinition to) {
        var body=new MethodBody(to) {InitLocals=from.Body.InitLocals,MaxStackSize=from.Body.MaxStackSize};to.Body=body;
        foreach(var v in from.Body.Variables)body.Variables.Add(new VariableDefinition(T(v.VariableType)));
        var map=new Dictionary<Instruction,Instruction>();
        foreach(var i in from.Body.Instructions){var n=Instruction.Create(OpCodes.Nop);n.OpCode=i.OpCode;body.Instructions.Add(n);map[i]=n;}
        foreach(var i in from.Body.Instructions) {
            object o=i.Operand;
            if(o is Instruction)o=map[(Instruction)o];
            else if(o is Instruction[])o=((Instruction[])o).Select(x=>map[x]).ToArray();
            else if(o is VariableDefinition)o=body.Variables[((VariableDefinition)o).Index];
            else if(o is ParameterDefinition)o=to.Parameters[((ParameterDefinition)o).Index];
            else if(o is TypeReference)o=T((TypeReference)o);
            else if(o is FieldReference)o=F((FieldReference)o);
            else if(o is MethodReference)o=M((MethodReference)o);
            else if(o is CallSite)throw new Exception("Unexpected calli");
            map[i].Operand=o;
        }
        foreach(var e in from.Body.ExceptionHandlers)body.ExceptionHandlers.Add(new ExceptionHandler(e.HandlerType) {
            CatchType=e.CatchType==null?null:T(e.CatchType),TryStart=map[e.TryStart],TryEnd=e.TryEnd==null?null:map[e.TryEnd],
            HandlerStart=map[e.HandlerStart],HandlerEnd=e.HandlerEnd==null?null:map[e.HandlerEnd],FilterStart=e.FilterStart==null?null:map[e.FilterStart]
        });
    }
    public static byte[] Run(byte[] donor,byte[] original,string[] selected) {
        using(var resolver=new LauncherAssemblyResolver(original)) {
            var parameters=new ReaderParameters {AssemblyResolver=resolver};
            using(var a=AssemblyDefinition.ReadAssembly(new System.IO.MemoryStream(donor),parameters))using(var b=AssemblyDefinition.ReadAssembly(new System.IO.MemoryStream(original),parameters)) {
                var p=new RestoreDownload(a.MainModule,b.MainModule);
                foreach(var name in selected) {
                    var m=All(a.MainModule.Types).SelectMany(x=>x.Methods).Single(x=>x.FullName==name);
                    MethodDefinition dest;
                    if(!p.methods.TryGetValue(m.FullName,out dest))throw new Exception("Missing destination: "+m.FullName);
                    p.Copy(m,dest);p.changed.Add("Restored "+m.FullName);
                }
                if(b.MainModule.AssemblyReferences.Any(x=>x.Name==a.Name.Name))throw new Exception("Accidental self reference");
                using(var output=new System.IO.MemoryStream()) {b.Write(output);return output.ToArray();}
            }
        }
    }
}
